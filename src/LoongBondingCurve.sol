// SPDX-License-Identifier: MIT
// Modifications Copyright (c) 2026 Genius
// Modifications Copyright (c) 2026 Loong: renamed from Genius; Loong's changes are listed in README.md.
// Original notices above are retained as the licence requires.
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LoongBondingCurveMath} from "./libraries/LoongBondingCurveMath.sol";
import {FoundationFeePolicy, FoundationFeeMath, ILoongFoundationFees} from "./interfaces/ILoongFoundationFees.sol";
import {LoongFoundationVault} from "./LoongFoundationVault.sol";
import {LoongBuybackVault} from "./LoongBuybackVault.sol";
import {LoongLauncherToken} from "./LoongLauncherToken.sol";
import {FeePolicySnapshot, ILoongFeeEscrow, ILoongFeePolicy, ILoongSnipeTax} from "./interfaces/ILaunchpadV2.sol";
import {ILoongLaunchFactoryGraduation} from "./interfaces/ILaunchpadV2Graduation.sol";

/**
 * @title LoongBondingCurve
 * @notice Constant-product bonding curve for one v2 launch, adapted from
 * BootstrapPool.sol (code-423n4/2025-01-iq-ai). The curve trades against the
 * same quote asset its graduated Uniswap V4 pool will use: native ETH when
 * `pairToken` is the zero address, otherwise that ERC-20. Collecting the
 * eventual pool asset from the very first trade is what lets graduation seed
 * the pool directly, with no swap and therefore no price oracle anywhere in
 * the system.
 *
 * Every trade fee is charged against the quote leg regardless of trade
 * direction, so the curve never accrues fees denominated in the memecoin:
 * protocol and creator revenue is quote-denominated from the first trade,
 * before graduation ever happens. Fees are split and swept under the policy
 * frozen for this launch, the same one the post-graduation hook applies so
 * both phases behave identically: either the legacy three-way
 * protocol/creator/buyback-and-lock split, or, when the hook carried a
 * Foundation vault at launch, the Foundation four-way split of destination,
 * platform, creator and buyback-and-burn. The Foundation buyback leg burns
 * the memecoin it buys back rather than locking it, so a Foundation launch's
 * `totalSupply` shrinks under protocol action; `launchSupply` is what records
 * the supply the launch was configured around.
 */
contract LoongBondingCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant MAX_TOTAL_TRADE_FEE_BPS = 2_000; // 20%

    error CurveGraduated();
    error ZeroAmount();
    error ZeroAddress();
    error SlippageExceeded(uint256 actual, uint256 minimum);
    error NotFactory();
    error TransferFailed();
    error AlreadyGraduated();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidLaunchEconomics();
    error NotReadyToGraduate();
    error NotFeeSweepOperator();
    error InternalSwapRequiresOperator();
    error InvalidFeePolicy();
    error MinimumOutputRequired();
    error NativeValueMismatch(uint256 supplied, uint256 expected);
    error UnexpectedNativeValue();
    error NotFactoryOwner();
    error CreatorRecipientChangeRequiresTimelock();
    error GraduationRescueTooEarly(uint256 availableAt);

    // `fee` and `tax` are reported separately because they fund different
    // parties: the fee splits across protocol, buyback and creator, while the
    // tax is paid to the creator in full.
    event CurveBuy(
        address indexed buyer, address indexed recipient, uint256 quoteIn, uint256 tokensOut, uint256 fee, uint256 tax
    );
    event CurveBuyRefunded(address indexed buyer, uint256 refund);
    event CurveSell(
        address indexed seller, address indexed recipient, uint256 tokensIn, uint256 quoteOut, uint256 fee, uint256 tax
    );
    event FeesSwept(uint256 protocolAmount, uint256 buybackAmount, uint256 creatorAmount);
    event FeesRescued(
        address indexed protocolRecipient,
        address indexed creatorRecipient,
        uint256 protocolAmount,
        uint256 creatorAmount
    );
    event BuybackLocked(uint256 quoteSpent, uint256 tokensLocked);
    event CurveCompleted(address recipient, uint256 quoteOut, uint256 tokenOut);
    event Initialized(address token);
    event CreatorFeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event BuybackEnabledUpdated(bool enabled);
    event AutoGraduationFailed(address indexed token, uint256 gasRemaining);
    event SnipeTaxExempted(address indexed account);
    // Separate from CurveBuy so indexers can tell an ordinary fee from a
    // launch-window penalty and surface which wallets sniped the launch.
    event SnipeTaxCharged(address indexed recipient, uint256 amount);

    // Not immutable: the token's constructor needs this curve's real address,
    // so the factory deploys the curve first, then the token, then wires the
    // token here via `initialize()`. Set exactly once, guarded by onlyFactory.
    address public token;
    // Quote asset for both curve trading and the graduated pool. The zero
    // address denotes native ETH.
    address public immutable pairToken;
    // Not immutable: the creator can hand off future fee sweeps to a new
    // address (or the factory can override on the protocol owner's behalf)
    // via `setCreatorFeeRecipient`, both gated through `onlyFactory`.
    address public deployer;
    address public immutable factory;
    ILoongFeePolicy public immutable feePolicy;
    ILoongFeeEscrow public immutable feeEscrow;
    LoongBuybackVault public immutable buybackVault;
    // These terms are frozen when the launch is created. Global hook policy
    // updates affect future launches but cannot redirect an active curve's
    // protocol share or change its buyback economics.
    address public immutable protocolFeeRecipient;
    address public immutable buybackCreatorRecipient;
    uint16 public immutable protocolFeeShareBps;
    uint16 public immutable buybackBurnBps;
    uint16 public immutable maxInternalPriceImpactBps;
    // Virtual quote reserve seeded at deploy, denominated in the quote
    // asset's own decimals rather than always in wei.
    uint256 public immutable phantomQuote;
    uint256 public immutable feeBps;
    // Creator-chosen at launch, capped by the protocol at launch time. Kept
    // entirely separate from feeBps: it is layered on top of the base trade
    // fee, not part of the protocol/buyback/creator split, and is paid to
    // the creator in full.
    uint256 public immutable creatorTaxBps;
    uint256 public immutable graduationThreshold;
    bool public buybackEnabled;

    uint256 public quoteFeeBalance;
    // The slice of `quoteFeeBalance` already earmarked for buyback-and-lock,
    // set aside as each fee was charged under whatever the buyback flag said
    // at that moment. Bucketing at accrual rather than deriving the slice at
    // sweep time keeps the flag forward-looking: toggling it decides how the
    // next trade's fee is split, never how an already-charged one is. It is
    // not a separate pot, only a marker on part of the pending balance, so
    // the protocol's share is still taken off the whole fee.
    FoundationFeePolicy private _foundationFeePolicy;
    bool public toFoundation;
    uint256 public destinationQuoteBalance;
    uint256 public platformQuoteBalance;
    event LaunchFoundationFeePolicy(
        address indexed token,
        bool toFoundation,
        address foundationVault,
        uint16 destinationBps,
        uint16 platformBps,
        uint16 creatorBps,
        uint16 buybackBps
    );
    event BuybackBurned(uint256 quoteSpent, uint256 tokensBurned);
    event FoundationFeesSwept(
        address indexed token, address indexed asset, address indexed foundationVault, uint256 amount
    );
    event FoundationFeesDeferred(
        address indexed token, address indexed asset, address indexed foundationVault, uint256 amount
    );
    uint256 public buybackQuoteBalance;
    uint256 public creatorTaxBalance;
    // Net real quote asset held from curve trading: buys add their value,
    // sell payouts and swept protocol/creator fees subtract theirs. Tracked
    // explicitly instead of reading a live balance, so a forced transfer in
    // (an ERC-20 airdrop, or ETH from a selfdestruct) can neither inflate
    // curve pricing nor push a launch past its graduation threshold with no
    // tokens actually sold.
    uint256 public trackedQuote;
    // Launch tokens this curve holds as tradeable reserve: set to the minted
    // allocation at initialize, reduced by buys and the internal buyback,
    // increased by sells. The token side needs the same treatment as the
    // quote side because both feed the constant-product price. Reading a
    // live balance would let any holder transfer tokens straight in to move
    // the curve's pricing, delay graduation past the point the launch's
    // economics were quoted at, and shift what the graduated pool opens at.
    uint256 public trackedTokens;
    bool public graduated;
    // Token balance the curve will never sell below, set once at initialize
    // and handed to the graduated pool intact. Everything above it is the
    // sellable allocation, and graduation is exactly its exhaustion.
    uint256 public reservedTokens;
    // Total supply this launch was created with, snapshotted at initialize on
    // every launch, legacy and Foundation alike. Held here rather than read
    // live from the token because the token is burnable by any holder as well
    // as by the Foundation buyback leg, so its own totalSupply stops
    // describing the supply the launch was configured around. Read on-chain by
    // LoongGraduationAllocation as well as by off-chain consumers.
    uint256 public launchSupply;
    // Timestamp trading opened, anchoring the snipe tax decay. Set once at
    // initialize, which the factory calls in the launch transaction itself,
    // so second zero of the decay is the launch second.
    uint256 public launchedAt;
    // Timestamp the sellable allocation ran out, anchoring the delay the
    // factory's rescueSweptGraduation waits out before it may release a
    // curve that is ready but whose sweep into the factory cannot land.
    // Zero until then; written once, whether or not the graduation that
    // follows succeeds, since readiness closes both trade sides and is
    // therefore final.
    uint256 public readyAt;
    // Anti-snipe tax terms, snapshotted from the factory at initialize like
    // the rest of this launch's economics. Frozen rather than read live so
    // a factory retune can never change the terms of a launch whose window
    // is already open: a launch created before the change keeps the setting
    // it was created under. A zero starting tax disables the mechanism for
    // this curve permanently.
    uint256 public snipeTaxStartBps;
    uint256 public snipeTaxSeconds;
    // Wallets the creator declared at launch, exempt from the snipe tax so
    // a team's own bundled buys are not eaten by the launch window's
    // anti-bot pricing. Written only by the factory during the launch
    // transaction.
    mapping(address account => bool exempt) public snipeTaxExempt;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyInitialized() {
        if (token == address(0)) revert NotInitialized();
        _;
    }

    /**
     * @param pairToken_ Quote asset for curve trading and the graduated pool; zero for native ETH.
     * @param deployer_ Token creator, credited as the creator fee recipient.
     * @param factory_ LoongLaunchFactory address, the only caller allowed through `onlyFactory`.
     * @param feePolicy_ Shared policy used only for the rotatable sweep operator.
     * @param policy_ Economic terms frozen for this launch's fee sweeps.
     * @param feeEscrow_ Shared claimable balance ledger for both ETH and ERC-20 revenue.
     * @param buybackVault_ Shared five-year vesting lock the legacy buyback leg deposits into. Mandatory on
     * every launch: a zero address reverts `ZeroAddress` below, and the value is stored as the immutable
     * `buybackVault` either way. A Foundation launch simply never deposits into it, because its buyback leg
     * burns the memecoin it buys back instead of locking it, but it must still be supplied a real vault.
     * @param phantomQuote_ Virtual quote reserve seeded at deploy, never physically held.
     * @param feeBps_ Trade fee in basis points, always charged on the quote leg.
     * @param creatorTaxBps_ Additional creator-chosen trade tax in basis points, layered on top of feeBps_.
     * @param buybackEnabled_ Whether this launch initially routes its configured fee share into buyback-and-lock.
     * @param graduationThreshold_ Real quote reserve required before graduation unlocks.
     */
    constructor(
        address pairToken_,
        address deployer_,
        address factory_,
        ILoongFeePolicy feePolicy_,
        FeePolicySnapshot memory policy_,
        ILoongFeeEscrow feeEscrow_,
        LoongBuybackVault buybackVault_,
        uint256 phantomQuote_,
        uint256 feeBps_,
        uint256 creatorTaxBps_,
        bool buybackEnabled_,
        uint256 graduationThreshold_
    ) {
        if (deployer_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        if (address(feePolicy_) == address(0) || address(feeEscrow_) == address(0)) revert ZeroAddress();
        if (address(buybackVault_) == address(0)) revert ZeroAddress();
        if (
            policy_.protocolFeeRecipient == address(0) || policy_.protocolFeeShareBps > BASIS_POINTS
                || policy_.buybackBurnBps > BASIS_POINTS || policy_.maxInternalPriceImpactBps == 0
                || policy_.maxInternalPriceImpactBps >= BASIS_POINTS
        ) {
            revert InvalidFeePolicy();
        }
        // The factory applies the same ceiling before deploying, but the curve
        // defends its own invariant rather than inheriting it: a combined fee
        // at or above the whole trade would break the quote accounting.
        if (feeBps_ + creatorTaxBps_ > MAX_TOTAL_TRADE_FEE_BPS) revert InvalidFeePolicy();

        pairToken = pairToken_;
        deployer = deployer_;
        // Passed explicitly rather than read from msg.sender: LoongLaunchFactory
        // deploys this curve indirectly through LoongLaunchDeployer to keep its
        // own bytecode under EIP-170's size limit, so msg.sender at construction
        // time would otherwise resolve to that deployer helper, not the factory.
        factory = factory_;
        feePolicy = feePolicy_;
        feeEscrow = feeEscrow_;
        buybackVault = buybackVault_;
        protocolFeeRecipient = policy_.protocolFeeRecipient;
        buybackCreatorRecipient = deployer_;
        protocolFeeShareBps = policy_.protocolFeeShareBps;
        buybackBurnBps = policy_.buybackBurnBps;
        maxInternalPriceImpactBps = policy_.maxInternalPriceImpactBps;
        phantomQuote = phantomQuote_;
        try ILoongFoundationFees(address(feePolicy_)).currentFoundationFeePolicy() returns (
            FoundationFeePolicy memory f
        ) {
            if (f.foundationVault != address(0)) {
                if (creatorTaxBps_ != 0 || !buybackEnabled_) revert InvalidFeePolicy();
                _foundationFeePolicy = f;
                feeBps_ = FoundationFeeMath.total(f);
            }
        } catch {}
        feeBps = feeBps_;
        creatorTaxBps = creatorTaxBps_;
        buybackEnabled = buybackEnabled_;
        graduationThreshold = graduationThreshold_;
    }

    /**
     * @notice True when this launch trades and graduates against native ETH.
     */
    function isNativeQuote() public view returns (bool) {
        return pairToken == address(0);
    }

    /**
     * @notice Wires the launch token this curve dispenses. Called once by the
     * factory immediately after deploying the token with this curve's (now
     * known) address, before either contract is reachable by anyone else.
     *
     * @dev Also fixes the pool's token allocation, which is why this cannot
     * happen in the constructor: the supply is only known once the token
     * exists. Holding `phantomQuote * supply` constant, the curve reaches a
     * real quote reserve of `graduationThreshold` exactly when its token
     * balance falls to `supply * phantomQuote / (phantomQuote + threshold)`.
     * Reserving that balance therefore does not change where a launch
     * graduates, it only stops the curve selling through it: the quote
     * threshold and the token allocation are the same point, so whichever
     * one is used as the trigger, the graduated pool is seeded with the same
     * amounts at the same price on every launch.
     */
    function initialize(address token_) external onlyFactory {
        if (token != address(0)) revert AlreadyInitialized();
        if (token_ == address(0)) revert ZeroAddress();
        token = token_;

        uint256 supply = IERC20(token_).totalSupply();
        uint256 reserved = Math.mulDiv(supply, phantomQuote, phantomQuote + graduationThreshold);
        // A launch whose allocation rounds away has nothing to seed its pool
        // with, and its final buy would revert against an empty token side.
        // Rejecting the config here fails at launch rather than at graduation.
        if (reserved == 0 || reserved >= supply) revert InvalidLaunchEconomics();
        reservedTokens = reserved;
        launchSupply = supply;
        launchedAt = block.timestamp;
        // Every launch opens under the snipe tax, whichever fee regime it
        // uses. Under the Foundation regime the tax joins the trading fee
        // bucket and splits by the same frozen Foundation shares.
        snipeTaxStartBps = ILoongSnipeTax(factory).snipeTaxStartBps();
        snipeTaxSeconds = ILoongSnipeTax(factory).snipeTaxSeconds();
        if (_foundationFeePolicy.foundationVault != address(0)) {
            FoundationFeePolicy memory f = _foundationFeePolicy;
            emit LaunchFoundationFeePolicy(
                token_, toFoundation, f.foundationVault, f.destinationBps, f.platformBps, f.creatorBps, f.buybackBps
            );
        }
        // The allocation the curve actually received, which is the whole
        // supply: the token mints to this curve in its own constructor.
        trackedTokens = IERC20(token_).balanceOf(address(this));

        emit Initialized(token_);
    }

    /**
     * @notice Tokens still available to buy before the curve graduates.
     */
    function sellableTokens() public view returns (uint256) {
        uint256 tracked = trackedTokens;
        return tracked > reservedTokens ? tracked - reservedTokens : 0;
    }

    /**
     * @notice Snipe tax `recipient` would pay on a buy landing right now, in
     * basis points of the quote leg. Starts at this launch's frozen
     * `snipeTaxStartBps` in the launch second and decays exponentially to
     * zero across `snipeTaxSeconds`, both snapshotted from the factory when
     * the curve initialized. Exempt wallets and a disabled tax both read as
     * zero.
     * @dev The decay is fourteen successive halvings spread evenly across
     * the window, done with right shifts so it stays in integer arithmetic.
     * Fourteen because 2^14 exceeds the maximum 9,900 starting tax, so the
     * tax always reaches zero inside the window rather than cutting off at
     * a still-meaningful rate. The decay anchors to `launchedAt`, set in
     * the launch transaction itself, so second zero is the first second the
     * token is publicly buyable.
     */
    function currentSnipeTaxBps(address recipient) public view returns (uint256) {
        if (snipeTaxExempt[recipient]) return 0;
        uint256 startBps = snipeTaxStartBps;
        if (startBps == 0) return 0;
        uint256 elapsed = block.timestamp - launchedAt;
        uint256 window = snipeTaxSeconds;
        if (elapsed >= window) return 0;
        return startBps >> ((elapsed * 14) / window);
    }

    /**
     * @notice Marks `account` as exempt from the snipe tax. Called by the
     * factory during the launch transaction for the creator, their fee
     * recipient, and any bundle wallets the creator declared, so a team's
     * own opening buys clear at the untaxed price while sniper bots in the
     * same window do not.
     */
    function exemptFromSnipeTax(address account) external onlyFactory {
        snipeTaxExempt[account] = true;
        emit SnipeTaxExempted(account);
    }

    /**
     * @notice Updates who receives creator fees from future sweeps.
     * Restricted to the factory, which gates both self-service creator
     * transfers and protocol-owner overrides before forwarding here, so
     * this contract only needs to trust one caller.
     */
    function setCreatorFeeRecipient(address newRecipient) external onlyFactory {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit CreatorFeeRecipientUpdated(deployer, newRecipient);
        deployer = newRecipient;
    }

    /**
     * @notice Enables or disables this launch's buyback-and-lock fee route.
     * The factory authorizes both the current creator recipient and protocol
     * owner before forwarding the setting here.
     * @dev Applies to fees charged from here on, not to fees already pending.
     * Each trade earmarks its buyback slice as it is charged, so a toggle
     * cannot reach back and reroute value that accrued under the opposite
     * setting. Without that, a disable landing before a sweep would divert a
     * buyback the creator had already earned into their own payout, and an
     * enable would sweep fees earned under a plain split into the vest.
     */
    function setBuybackEnabled(bool enabled) external onlyFactory {
        if (_foundationFeePolicy.foundationVault != address(0) && !enabled) revert InvalidFeePolicy();
        buybackEnabled = enabled;
        emit BuybackEnabledUpdated(enabled);
    }

    /**
     * @notice Returns the curve's current tradeable reserves, excluding fees pending sweep.
     */
    function getReserves() public view returns (uint256 quoteReserve_, uint256 tokenReserve_) {
        quoteReserve_ = phantomQuote + trackedQuote - quoteFeeBalance - creatorTaxBalance;
        tokenReserve_ = trackedTokens;
    }

    /**
     * @notice Tradeable quote reserve only, matching ILoongBondingCurve.
     */
    function quoteReserve() external view returns (uint256 quoteReserve_) {
        (quoteReserve_,) = getReserves();
    }

    /**
     * @notice Returns physically held tradeable quote asset, excluding virtual
     * liquidity and balances already earmarked as fees or creator tax.
     */
    function realQuoteReserve() public view returns (uint256) {
        return trackedQuote - quoteFeeBalance - creatorTaxBalance;
    }

    /**
     * @notice Tradeable token reserve only, matching ILoongBondingCurve.
     */
    function tokenReserve() external view returns (uint256 tokenReserve_) {
        (, tokenReserve_) = getReserves();
    }

    /**
     * @notice True once the curve's sellable allocation has been bought out.
     * @dev Equivalent to the real quote reserve reaching `graduationThreshold`,
     * since the reserved balance is derived from that same point. Expressed
     * against the token side because that is the one a buy cannot overshoot:
     * the quote side is a floor that a large trade could sail past, while the
     * token side is a hard stop the curve refuses to cross.
     */
    function readyToGraduate() public view returns (bool) {
        if (graduated) return false;
        return sellableTokens() == 0;
    }

    /**
     * @notice Buys the launch token with this launch's quote asset. The fee is
     * always taken from the quote leg, so this curve never holds a
     * memecoin-denominated fee.
     * @dev `quoteIn` must equal `msg.value` for a native launch, and must be
     * accompanied by no value at all for an ERC-20 launch. The credited
     * amount for an ERC-20 is the observed balance delta rather than the
     * requested amount, so a fee-on-transfer quote asset cannot make the
     * curve promise reserves it never received.
     *
     * A buy that would take the curve past its reserved allocation is filled
     * only up to that allocation, charged for what it actually received, and
     * refunded the difference. It is deliberately not rejected: the last buy
     * of a launch is the one most likely to be sized against a state someone
     * else has already moved, and reverting would let anyone grief it by
     * slipping a small buy in ahead.
     *
     * Buys landing in the opening seconds of a launch additionally pay the
     * decaying snipe tax (see `currentSnipeTaxBps`) unless the recipient was
     * exempted at launch. The tax comes off the quote leg before pricing, so
     * a sniper's spend mostly accrues as fees instead of buying tokens, and
     * it decays to nothing within seconds for ordinary buyers.
     *
     * Partial fills reinterpret `minTokensOut` as a bound on price rather
     * than on quantity, since a caller who spends less than they offered
     * cannot expect the whole quantity they asked for. The requirement is
     * that the price paid is no worse than the price implied by the caller's
     * own arguments, and when nothing is clamped it reduces exactly to
     * `tokensOut >= minTokensOut`.
     */
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
        onlyInitialized
        returns (uint256 tokensOut)
    {
        if (graduated) revert CurveGraduated();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 received = _receiveQuote(quoteIn);
        if (received == 0) revert ZeroAmount();
        // graduate() is deliberately not nonReentrant and the factory's
        // trigger is permissionless, so a quote asset that yields control
        // during transferFrom can drain this curve between the check above
        // and the reserve reads below. Re-checking here rather than relying
        // on the downstream arithmetic to happen to revert.
        if (graduated) revert CurveGraduated();

        uint256 quoteReserveBefore = phantomQuote + trackedQuote - quoteFeeBalance - creatorTaxBalance;
        uint256 tokenReserveBefore = trackedTokens;

        // The snipe tax rides the quote leg like the base fee and creator
        // tax, but is bounded so the combined take always nets the buyer at
        // least 1% of their spend and the gross-up below never divides by
        // zero. It deliberately ignores MAX_TOTAL_TRADE_FEE_BPS: a 99% take
        // in the launch second is the entire point. The bound only matters
        // to a nonzero tax, so the common untaxed buy skips it.
        uint256 snipeTaxBps = currentSnipeTaxBps(recipient);
        if (snipeTaxBps != 0) {
            uint256 maxSnipeTaxBps = BASIS_POINTS - feeBps - creatorTaxBps - 100;
            if (snipeTaxBps > maxSnipeTaxBps) snipeTaxBps = maxSnipeTaxBps;
        }

        uint256 spent = received;
        uint256 fee = (spent * feeBps) / BASIS_POINTS;
        uint256 tax = (spent * creatorTaxBps) / BASIS_POINTS;
        uint256 snipeTax = (spent * snipeTaxBps) / BASIS_POINTS;
        tokensOut = LoongBondingCurveMath.getAmountOut(
            spent - fee - tax - snipeTax, quoteReserveBefore, tokenReserveBefore, 0
        );

        uint256 sellable = tokenReserveBefore > reservedTokens ? tokenReserveBefore - reservedTokens : 0;
        if (sellable == 0) revert CurveGraduated();

        if (tokensOut > sellable) {
            tokensOut = sellable;
            // Price the clamped fill from the token side, then gross the
            // result back up so the fee legs still come out of the input.
            uint256 net = LoongBondingCurveMath.getAmountIn(sellable, quoteReserveBefore, tokenReserveBefore, 0);
            spent = Math.min(
                Math.mulDiv(net, BASIS_POINTS, BASIS_POINTS - feeBps - creatorTaxBps - snipeTaxBps, Math.Rounding.Ceil),
                received
            );
            fee = (spent * feeBps) / BASIS_POINTS;
            tax = (spent * creatorTaxBps) / BASIS_POINTS;
            snipeTax = (spent * snipeTaxBps) / BASIS_POINTS;
        }

        // Price bound rather than quantity bound, so a partial fill honours
        // the caller's terms instead of failing them. Identical to
        // `tokensOut >= minTokensOut` whenever `spent == received`.
        if (spent * minTokensOut > received * tokensOut) revert SlippageExceeded(tokensOut, minTokensOut);

        // The snipe tax joins the base fee bucket, so it splits between
        // protocol, creator, and buyback under the launch's frozen policy
        // through the ordinary sweep path instead of needing accounting of
        // its own.
        _accrueFees(fee + snipeTax, tax);
        trackedQuote += spent;
        trackedTokens -= tokensOut;
        _noteReadiness();
        IERC20(token).safeTransfer(recipient, tokensOut);

        uint256 refund = received - spent;
        if (refund != 0) {
            emit CurveBuyRefunded(msg.sender, refund);
            _sendQuote(msg.sender, refund);
        }

        if (snipeTax != 0) emit SnipeTaxCharged(recipient, snipeTax);
        emit CurveBuy(msg.sender, recipient, spent, tokensOut, fee + snipeTax, tax);
        _tryAutoGraduate();
    }

    /**
     * @notice Sells the launch token back to the curve for the quote asset.
     * The fee is taken from the quote output, so it is always
     * quote-denominated here too.
     * @dev Closed once the sellable allocation is exhausted, not merely once
     * `graduated` is set. `_tryAutoGraduate` swallows a failed graduation so
     * a problem there cannot take the crossing buy down with it, which leaves
     * a window where the curve is ready but the flag is still false. `buy`
     * already refuses that state through its own `sellable == 0` check, and
     * `sell` has to match: `graduate` hands the pool whatever `trackedTokens`
     * holds, so a sell landing in the window would put tokens back on the
     * curve and take quote off it, and the pool would then be seeded deeper
     * and cheaper than the reserved allocation fixes it at. The deterministic
     * graduation price only holds if the window is closed on both sides.
     *
     * This cannot strand a holder. `graduate` is permissionless, so anyone
     * blocked here can settle the launch themselves in the same transaction
     * and trade the V4 pool instead.
     */
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient)
        external
        nonReentrant
        onlyInitialized
        returns (uint256 quoteOut)
    {
        if (graduated || readyToGraduate()) revert CurveGraduated();
        if (tokensIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        (uint256 quoteReserveBefore, uint256 tokenReserveBefore) = getReserves();
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);

        uint256 grossQuoteOut = LoongBondingCurveMath.getAmountOut(tokensIn, tokenReserveBefore, quoteReserveBefore, 0);
        uint256 fee = (grossQuoteOut * feeBps) / BASIS_POINTS;
        uint256 tax = (grossQuoteOut * creatorTaxBps) / BASIS_POINTS;
        quoteOut = grossQuoteOut - fee - tax;
        if (quoteOut < minQuoteOut) revert SlippageExceeded(quoteOut, minQuoteOut);

        _accrueFees(fee, tax);
        trackedQuote -= quoteOut;
        trackedTokens += tokensIn;
        _sendQuote(recipient, quoteOut);

        emit CurveSell(msg.sender, recipient, tokensIn, quoteOut, fee, tax);
    }

    /**
     * @notice Distributes pending quote fees using this launch's frozen
     * policy: a legacy launch splits across protocol, buyback-and-lock and the
     * creator, while a Foundation launch splits across destination, platform,
     * creator and buyback-and-burn, burning the memecoin its buyback leg
     * acquires rather than locking it, which lowers `totalSupply`. Only the
     * trusted sweep operator may execute the internal buyback; a creator sweep
     * never does. Under the Foundation policy the creator may still sweep
     * while a buyback slice is pending, because that sweep retains the burn
     * funding untouched for the operator and distributes only the platform,
     * destination and creator legs. A legacy launch refuses the creator while
     * an earmark is pending, since its swap-free sweep folds the earmark into
     * the creator's own payout.
     * @dev Reverts once graduated rather than silently no-op'ing. `graduate()`
     * already drains `quoteFeeBalance`/`creatorTaxBalance` to zero before
     * setting the flag, and trading is halted afterward so they can never
     * refill, but making the guard explicit here keeps that invariant
     * self-evident instead of depending on reasoning across two functions.
     */
    function sweepFees(uint256 minBuybackTokensOut) external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        bool isOperator = msg.sender == feePolicy.feeSweepOperator();
        if (!isOperator && msg.sender != deployer) {
            revert NotFeeSweepOperator();
        }
        if (!isOperator && _requiresTrustedOperator()) {
            // Under the legacy policy the swap-free sweep clears the earmark
            // into the creator's own payout, so the creator has to wait for
            // the operator. Under the Foundation policy `_sweepFees(0, false)`
            // routes to `_sweepFoundationFees`, which retains the whole burn
            // funding exactly as `_graduate` and `_rescueFees` already do, so
            // the creator distributes only the platform, destination and
            // creator legs and never chooses a price floor for the burn.
            if (_foundationFeePolicy.foundationVault == address(0)) revert InternalSwapRequiresOperator();
            _sweepFees(0, false);
        } else {
            _sweepFees(minBuybackTokensOut, true);
        }
        _tryAutoGraduate();
    }

    /**
     * @notice Sweeps fees, halts trading, and hands the remaining tradeable
     * reserves to the factory so it can seed the graduated Uniswap V4 pool.
     * Because the curve already holds the pool's quote asset, the factory
     * receives exactly what it needs to seed with, and no conversion step
     * sits between the two. Restricted to the factory; deliberately not
     * `nonReentrant` since it may be invoked from within `buy()`'s own
     * reentrancy-guarded scope.
     */
    function graduate(address recipient) external onlyFactory returns (uint256 quoteOut, uint256 tokenOut) {
        return _graduate(recipient, false);
    }

    /**
     * @notice Sweeps fees, halts trading, and hands the remaining tradeable
     * reserves to `recipient` instead of to the factory, for a launch whose
     * quote asset refuses to deliver to the factory. Restricted to the
     * factory, which gates it on the protocol owner, and to a curve that has
     * sat ready and ungraduated for the factory's GRADUATION_RESCUE_DELAY.
     * @dev `graduate` stays permissionless throughout that wait, so anyone
     * can end the window early by settling the launch normally, and the
     * delay only ever expires on a curve nobody could graduate. That is what
     * bounds the owner here: the power reaches exactly the reserves the
     * ordinary path cannot move. Pending fees still sweep to the escrow
     * first, as they do in `graduate`; a launch whose asset also refuses the
     * escrow can be cleared beforehand with the factory's `rescueCurveFees`,
     * or with `rescueFeesTo` when the asset also refuses a recorded
     * recipient, and otherwise those buckets fold into this payout rather
     * than wedging it. Not `nonReentrant` for the same reason `graduate` is
     * not; the factory entry that reaches it is.
     *
     * This is the launch's terminal call, so it is also the one exit that
     * cannot be allowed to fail on the curve's own bookkeeping: it settles
     * the fees itself when the escrow refuses them, and it accepts an inexact
     * sender debit through `_sendQuoteRescue`. See both for why that is safe
     * only here.
     */
    function rescueGraduation(address recipient) external onlyFactory returns (uint256 quoteOut, uint256 tokenOut) {
        uint256 anchor = readyAt;
        if (anchor == 0) revert NotReadyToGraduate();
        uint256 availableAt = anchor + ILoongLaunchFactoryGraduation(factory).GRADUATION_RESCUE_DELAY();
        if (block.timestamp < availableAt) revert GraduationRescueTooEarly(availableAt);
        return _graduate(recipient, true);
    }

    /**
     * @dev Sweeps pending fees on behalf of `_graduate`'s rescue branch.
     * External only so that sweep is one catchable operation, the same shape
     * `depositFoundationFees` uses; `address(this)` is the only permitted
     * caller, so it adds no reachable power.
     */
    function sweepFeesForGraduationRescue() external {
        if (msg.sender != address(this)) revert NotFactory();
        _sweepFees(0, false);
    }

    /**
     * @dev What the ordinary settlement would have booked to the protocol and
     * to the creator, for the rescue fold that pays every bucket to one
     * recipient. These two numbers classify by economic destination on the
     * ordinary path, not by where the rescue happens to send the money, so
     * that the categories the `FeesRescued` fields name keep one meaning.
     *
     * Mirrors `_rescueFees` under the default policy: the protocol takes its
     * share of the base fee and the creator keeps the remainder plus the
     * whole tax, the buyback earmark included, exactly as a sweep with no
     * buyback leaves it. There the two do sum to everything folded.
     *
     * Under a Foundation policy it mirrors what `_sweepFoundationFees`
     * reports in `FeesSwept`, which is the platform leg and the creator
     * remainder alone. Two buckets are deliberately in neither number:
     *
     * - the destination leg, while `toFoundation` routes it to the vault.
     *   The ordinary sweep pays it to the Foundation vault and announces it
     *   as `FoundationFeesSwept`, a separate ledger from protocol revenue, so
     *   reporting it here as the protocol's would overstate protocol revenue
     *   by the whole Foundation contribution. Reporting it as the creator's
     *   would be worse. With `toFoundation` off the ordinary sweep gives that
     *   leg to the creator, and so does this.
     * - the retained burn funding, which funds a burn rather than either
     *   party and is reported by `FeesSwept` only once actually spent.
     *
     * So under a Foundation policy the pair sums to less than the fold pays
     * out. That is intended: the shortfall is money neither party earned, it
     * reached the rescue recipient with everything else, and `CurveCompleted`
     * already carries the total actually paid. Naming it on its own would
     * need a field `FeesRescued` does not have.
     *
     * The tax is structurally zero under a Foundation policy - the
     * constructor rejects a non-zero `creatorTaxBps` there - and is carried
     * in both branches so that stays true by construction rather than by
     * omission here.
     */
    function _pendingFeeSplit() private view returns (uint256 protocolAmount, uint256 creatorAmount) {
        uint256 pending = quoteFeeBalance;
        if (_foundationFeePolicy.foundationVault != address(0)) {
            uint256 destination = destinationQuoteBalance;
            protocolAmount = platformQuoteBalance;
            creatorAmount = pending - destination - protocolAmount - buybackQuoteBalance;
            if (!toFoundation) creatorAmount += destination;
        } else {
            protocolAmount = (pending * protocolFeeShareBps) / BASIS_POINTS;
            creatorAmount = pending - protocolAmount;
        }
        creatorAmount += creatorTaxBalance;
    }

    /**
     * @dev Shared body of `graduate` and `rescueGraduation`, which differ in
     * who may receive the reserves, when, and whether the payout may fail
     * open. `rescue` is true only on the owner's delayed terminal path.
     */
    function _graduate(address recipient, bool rescue) private returns (uint256 quoteOut, uint256 tokenOut) {
        if (graduated) revert AlreadyGraduated();
        if (recipient == address(0)) revert ZeroAddress();
        if (!readyToGraduate()) revert NotReadyToGraduate();

        // Halt trading before the sweep, not after. The sweep pays the escrow,
        // and a quote asset with a transfer callback can re-enter buy() or
        // sell() from inside that payment. This function is deliberately not
        // nonReentrant so it stays callable from within buy()'s own guarded
        // scope, so the flag is the only thing closing that window. Reentering
        // while it was still false repopulated the fee buckets after they had
        // been zeroed, leaving balances with no quote behind them once the
        // reserve was handed over, and no way to ever sweep them.
        //
        // Safe to set here: readyToGraduate() is already evaluated above, and
        // the private _sweepFees never reads the flag.
        graduated = true;

        // Graduation may be triggered by any caller or by the threshold-
        // crossing buyer. Skip the buyback rather than execute a predictable
        // market order without the sweep operator's minimum output.
        if (!rescue) {
            _sweepFees(0, false);
        } else {
            // The terminal rescue tries the ordinary sweep first, so a launch
            // whose asset refuses only the factory still pays its fees into
            // the escrow exactly as `graduate` would. When that sweep cannot
            // land at all - the escrow, the Foundation vault, or this curve's
            // own exact-debit check refuses it - the pending buckets fold
            // into the single payout below instead of wedging the one exit
            // the reserves have left. Folding is correct only here: this call
            // ends the launch, so after it no claimant remains on the curve
            // for these buckets to be owed to, and anything left behind would
            // be frozen for good. The failed attempt reverts atomically, so
            // the buckets read here are the ones it started from.
            //
            // The sibling branch is where a claimant can survive: a sweep
            // that does land under a Foundation policy retains the unspent
            // burn funding and any deferred destination leg for
            // `handoffBuyback` and `retryFoundationFees`. See
            // `_sendQuoteRescue` for what an over-debit can then reach.
            //
            // Starving the sub-call under the 63/64 rule would fold buckets
            // the escrow would in fact have taken. Only the owner reaches
            // this branch, and `rescueFeesTo` already lets them redirect the
            // same buckets on a ready curve, so it grants no new power.
            try this.sweepFeesForGraduationRescue() {}
            catch {
                // Every bucket goes to the one recipient, but the event still
                // reports the categories it names: indexers post these two
                // fields to protocol and creator revenue, so each must carry
                // what that party would have earned on the ordinary path and
                // nothing else. Under a Foundation policy that leaves part of
                // the fold in neither field; see `_pendingFeeSplit`. The
                // folded legs are inside the `CurveCompleted` total below,
                // unlike the escrow-credited legs of an ordinary sweep.
                (uint256 protocolAmount, uint256 creatorAmount) = _pendingFeeSplit();
                quoteFeeBalance = 0;
                buybackQuoteBalance = 0;
                creatorTaxBalance = 0;
                destinationQuoteBalance = 0;
                platformQuoteBalance = 0;
                emit FeesRescued(recipient, recipient, protocolAmount, creatorAmount);
            }
        }

        // Hand over only the tracked trading reserves. Any quote asset or
        // launch token force-sent to this curve is deliberately left stranded
        // here rather than folded into the graduated pool's seed, so a
        // donation cannot move the price the pool opens at.
        quoteOut = trackedQuote - quoteFeeBalance;
        trackedQuote = quoteFeeBalance;
        tokenOut = trackedTokens;
        trackedTokens = 0;

        if (quoteOut != 0) {
            if (rescue) {
                _sendQuoteRescue(recipient, quoteOut);
            } else {
                _sendQuote(recipient, quoteOut);
            }
        }
        if (tokenOut != 0) {
            IERC20(token).safeTransfer(recipient, tokenOut);
        }

        emit CurveCompleted(recipient, quoteOut, tokenOut);
    }

    /**
     * @dev Pulls `amount` of the quote asset from the caller and returns the
     * amount actually received. Native launches take it from `msg.value`;
     * ERC-20 launches measure the balance delta so a fee-on-transfer quote
     * asset is credited for what arrived, not what was asked for.
     */
    function _receiveQuote(uint256 amount) private returns (uint256) {
        if (isNativeQuote()) {
            if (msg.value != amount) revert NativeValueMismatch(msg.value, amount);
            return amount;
        }

        if (msg.value != 0) revert UnexpectedNativeValue();
        IERC20 quote = IERC20(pairToken);
        uint256 balanceBefore = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), amount);
        return quote.balanceOf(address(this)) - balanceBefore;
    }

    /**
     * @dev Pays `amount` of the quote asset out to `recipient`.
     */
    function _sendQuote(address recipient, uint256 amount) private {
        if (isNativeQuote()) {
            (bool sent,) = payable(recipient).call{value: amount}("");
            if (!sent) revert TransferFailed();
            return;
        }
        IERC20 quote = IERC20(pairToken);
        uint256 balanceBefore = quote.balanceOf(address(this));
        quote.safeTransfer(recipient, amount);
        uint256 balanceAfter = quote.balanceOf(address(this));
        if (balanceAfter > balanceBefore || balanceBefore - balanceAfter != amount) revert TransferFailed();
    }

    /**
     * @dev `_sendQuote` for the owner's terminal graduation rescue only, with
     * the exact-debit equality dropped.
     *
     * That equality exists to stop an approved asset that charges its sender
     * an extra unit per transfer from paying one claimant out of backing that
     * belongs to another. Everywhere else on this curve there is such another
     * claimant: the holders still trading it, or the fee buckets still owed
     * on it. Here there is all but none. `rescueGraduation` runs only after
     * the curve has sat ready and ungraduated for the factory's whole rescue
     * delay, with both trade sides shut and `graduated` already set, and it
     * hands over the entire tracked reserve and token side in one call,
     * having first settled or folded in every bucket.
     *
     * One residue is left, and only on a Foundation launch whose fee sweep
     * succeeded: that sweep retains the unspent burn funding and any deferred
     * destination leg in `quoteFeeBalance`, which `quoteOut` excludes and
     * which the hook's `handoffBuyback` and `retryFoundationFees` can still
     * pull afterwards. Their backing is the balance this payout may
     * over-debit, so an over-debit here can eat into them ahead of a
     * force-sent donation. That is confined to this one launch - one curve
     * holds one launch, and the factory's own rescue leg keeps the equality
     * because that contract does hold several launches' reserves at once -
     * and it is unreachable on mainnet, whose economics approve no ERC-20 pair
     * token at all. Testnet does ship one, so the configuration is live there.
     * When the sweep instead could not land, the fold above zeroes those
     * buckets and the residue does not exist.
     *
     * Shorting those buckets is accepted deliberately rather than guarded
     * against: everything an over-debit can still reach here is Foundation-
     * owned protocol revenue - the constructor forbids a creator tax under
     * this policy, so no creator or holder claim is ever backed by this
     * balance at graduation - and refusing the payout to protect it would put
     * the users' whole reserve back behind the same frozen asset, which is the
     * defect this function exists to remove.
     *
     * Keeping the equality here instead would close this exit too: the same
     * asset that stops `sell` from paying a holder stops the rescue from
     * paying anyone, and a launch's whole reserve would be frozen with no
     * on-chain path left to it. The equality is two-sided, so it refuses an
     * asset that over-debits its sender and an asset that under-debits it
     * alike, and the second needs no malicious issuer at all: share- or
     * reflection-accounted supply rounds a sender debit down on its own, and
     * an issuer that rescaled `balanceOf` for wallet compatibility would put
     * every curve in that asset into the same freeze. Both directions are
     * therefore accepted here.
     *
     * What survives is a single bound: the curve must be debited by SOMETHING.
     * `balanceAfter >= balanceBefore` reverts, so a credit back to the sender
     * and an asset that reports success while moving nothing are both refused,
     * exactly as they are everywhere else. Accepting a zero debit would mark
     * the launch terminally `Rescued`, clear `trackedQuote` and report the
     * nominal amount with the entire reserve still sitting on the dead curve -
     * a total loss, and the very outcome this path exists to prevent.
     *
     * The residue that buys is a positive but short debit: an asset that moves
     * the recipient's `amount` while debiting the curve less completes the
     * rescue and leaves the difference stranded on a curve nothing can reach
     * again. In the pathological limit that is a one-wei debit against a whole
     * reserve. It is accepted deliberately, as the smaller of two exposures:
     * rounding-down is an ordinary token behaviour and a freeze from it is
     * silent until a holder tries to exit, whereas a short debit is announced
     * on chain the moment it happens - `FeesRescued` and `CurveCompleted` both
     * fire with the nominal figures - and is confined to the one launch being
     * rescued.
     *
     * An asset that debits more than the curve holds still reverts inside its
     * own transfer, which no check here can change. Topping the curve up is
     * permissionless and the top-up is consumed by this same payout.
     */
    function _sendQuoteRescue(address recipient, uint256 amount) private {
        if (isNativeQuote()) {
            (bool sent,) = payable(recipient).call{value: amount}("");
            if (!sent) revert TransferFailed();
            return;
        }
        IERC20 quote = IERC20(pairToken);
        uint256 balanceBefore = quote.balanceOf(address(this));
        quote.safeTransfer(recipient, amount);
        uint256 balanceAfter = quote.balanceOf(address(this));
        // Any positive debit passes; only a zero debit and a credit revert.
        if (balanceAfter >= balanceBefore) revert TransferFailed();
    }

    /**
     * @dev Credits `amount` of the quote asset to `recipient`'s claimable
     * escrow balance, using whichever of the escrow's two ledgers matches.
     */
    function _creditQuote(address recipient, uint256 amount) private {
        if (isNativeQuote()) {
            feeEscrow.credit{value: amount}(recipient);
            return;
        }
        IERC20(pairToken).forceApprove(address(feeEscrow), amount);
        feeEscrow.creditToken(recipient, pairToken, amount);
    }

    /**
     * @dev Anchors the graduation rescue clock the moment the sellable
     * allocation is exhausted, on whichever path exhausted it: the crossing
     * buy, or an internal buyback that took the last sellable token. Written
     * ahead of the automatic graduation attempt rather than in its failure
     * branch, because that branch runs on whatever gas the crossing buyer
     * left it under the 63/64 rule, and a cold store there could take the
     * buy down with it. Readiness closes both trade sides, so the first
     * write is the only one.
     */
    function _noteReadiness() private {
        if (sellableTokens() == 0 && readyAt == 0) readyAt = block.timestamp;
    }

    /**
     * @dev Attempts to graduate the instant a buy crosses the threshold, so
     * the crossing trade itself triggers the migration atomically. Wrapped in
     * try/catch: if graduation reverts for any reason (for example a pool the
     * factory cannot yet seed), the underlying buy must still succeed, and
     * graduation stays permissionlessly retryable via the factory.
     *
     * A failure is announced rather than swallowed silently. The crossing
     * buyer sets their own gas limit and can starve this call under the 63/64
     * rule, pushing graduation's cost onto whoever calls next, so the event is
     * what lets a keeper notice a launch sitting ready but ungraduated.
     */
    function _tryAutoGraduate() private {
        if (readyToGraduate()) {
            try ILoongLaunchFactoryGraduation(factory).graduate(token) {}
            catch {
                emit AutoGraduationFailed(token, gasleft());
            }
        }
    }

    /**
     * @dev Books a trade's base fee and creator tax, earmarking the buyback
     * slice at the moment the fee is charged. The slice comes out of the
     * creator's bucket alone, so it is measured against what remains after
     * the protocol's share, and the tax never enters the split at all.
     */
    function _accrueFees(uint256 fee, uint256 tax) private {
        quoteFeeBalance += fee;
        creatorTaxBalance += tax;
        if (_foundationFeePolicy.foundationVault != address(0)) {
            (uint256 destination, uint256 platform,, uint256 burnAmount) =
                FoundationFeeMath.split(fee, _foundationFeePolicy);
            destinationQuoteBalance += destination;
            platformQuoteBalance += platform;
            buybackQuoteBalance += burnAmount;
            return;
        }
        if (buybackEnabled && fee != 0) {
            uint256 creatorSlice = fee - (fee * protocolFeeShareBps) / BASIS_POINTS;
            buybackQuoteBalance += (creatorSlice * buybackBurnBps) / BASIS_POINTS;
        }
    }

    /**
     * @dev Returns whether a pending base-fee balance would execute a
     * pool-priced buyback. The creator can distribute direct fees but cannot
     * choose a permissive price floor for inventory shared with the protocol.
     */
    function _requiresTrustedOperator() private view returns (bool) {
        return buybackQuoteBalance != 0;
    }

    /**
     * @dev A Foundation launch delegates the whole split to
     * `_sweepFoundationFees`, which burns the memecoin its buyback leg
     * acquires rather than locking it. Otherwise this splits pending quote
     * fees into protocol / buyback-and-lock / creator using the launch's
     * frozen policy, swapping the buyback slice for the memecoin against this
     * curve's own reserves before locking it into the shared five-year vest.
     * Reserves for the swap are read before `quoteFeeBalance` is cleared, so
     * the entire pending balance is correctly excluded from the pre-swap
     * tradeable reserve. The buyback's price impact is bounded by the same
     * `maxInternalPriceImpactBps` the post-graduation hook enforces on its own
     * internal swaps, and its size by the same `reservedTokens` floor `buy`
     * respects. A caller cannot execute the swap without supplying an explicit
     * output floor.
     */
    function _sweepFees(uint256 minBuybackTokensOut, bool executeBuyback) private {
        if (_foundationFeePolicy.foundationVault != address(0)) {
            _sweepFoundationFees(minBuybackTokensOut, executeBuyback, false, protocolFeeRecipient, deployer);
            return;
        }
        uint256 pending = quoteFeeBalance;
        uint256 tax = creatorTaxBalance;
        if (pending == 0 && tax == 0) return;

        uint256 protocolAmount = (pending * protocolFeeShareBps) / BASIS_POINTS;
        uint256 creatorBucket = pending - protocolAmount;
        // The earmark was summed per trade, so its rounding can land a wei or
        // two above the bucket recomputed here on the aggregate. Clamping
        // keeps the subtraction below sound at a full buyback share, where
        // the two would otherwise be equal.
        uint256 buybackAmount = executeBuyback ? Math.min(buybackQuoteBalance, creatorBucket) : 0;
        // The creator tax bypasses the protocol/buyback split entirely: it is
        // charged on top of the base fee and paid to the creator in full.
        uint256 creatorAmount = creatorBucket - buybackAmount + tax;

        uint256 tokensLocked;
        if (buybackAmount != 0) {
            if (minBuybackTokensOut == 0) revert MinimumOutputRequired();
            (uint256 quoteReserve_, uint256 tokenReserve_) = getReserves();
            // This reserve-movement ratio is equivalent to the hook's
            // sqrtPriceX96 limit for a constant-product quote-to-token swap.
            uint256 reserveMovementBps = (buybackAmount * BASIS_POINTS) / (quoteReserve_ + buybackAmount);
            if (reserveMovementBps <= maxInternalPriceImpactBps) {
                // The non-reverting quote, so a curve too thin to price the
                // buyback reaches the fold-back below instead of taking the
                // whole fee sweep down with it.
                uint256 tokensOut =
                    LoongBondingCurveMath.quoteAmountOut(buybackAmount, quoteReserve_, tokenReserve_, 0);
                // The buyback takes tokens off the same reserve `buy` does, so
                // it answers to the same floor. Only the balance above
                // `reservedTokens` is sellable; the remainder is the graduated
                // pool's allocation. As a launch nears graduation the sellable
                // amount approaches zero and the buyback folds back into the
                // creator payout below rather than eating into that allocation.
                if (tokensOut != 0 && tokensOut <= sellableTokens()) {
                    tokensLocked = tokensOut;
                }
            }
            if (tokensLocked == 0) {
                // Curve too shallow or the buyback would move its price too
                // far; fold it back into the creator's payout instead.
                creatorAmount += buybackAmount;
                buybackAmount = 0;
            } else if (tokensLocked < minBuybackTokensOut) {
                // Only a buyback that actually executes is subject to the
                // caller's minimum. Applying it to the fold-back branch would
                // make that branch unreachable, since every accepted argument
                // is above the zero it produces, and pending fees would be
                // stranded exactly when the curve is too thin to buy back.
                revert SlippageExceeded(tokensLocked, minBuybackTokensOut);
            }
        }

        quoteFeeBalance = 0;
        // Cleared unconditionally. Whether the buyback executed, folded back
        // into the creator's payout, or was skipped outright by graduation,
        // the fees behind the earmark have now been distributed.
        buybackQuoteBalance = 0;
        creatorTaxBalance = 0;
        // Protocol and creator amounts leave the contract; the buyback slice
        // stays as tradeable reserve, so only the paid-out legs reduce the
        // tracked quote balance.
        trackedQuote -= protocolAmount + creatorAmount;

        if (tokensLocked != 0) {
            // The buyback buys the memecoin off this curve's own reserve, so
            // the tokens it locks leave the tradeable side.
            trackedTokens -= tokensLocked;
            _noteReadiness();
            IERC20(token).forceApprove(address(buybackVault), tokensLocked);
            buybackVault.lock(token, tokensLocked, buybackCreatorRecipient, protocolFeeRecipient, protocolFeeShareBps);
            emit BuybackLocked(buybackAmount, tokensLocked);
        }
        if (protocolAmount != 0) {
            _creditQuote(protocolFeeRecipient, protocolAmount);
        }
        if (creatorAmount != 0) {
            _creditQuote(deployer, creatorAmount);
        }

        emit FeesSwept(protocolAmount, buybackAmount, creatorAmount);
    }

    /**
     * @notice Pays this curve's pending fees straight to the protocol and
     * creator recipients, bypassing the escrow. Restricted to the factory,
     * which gates it on the protocol owner.
     *
     * @dev Exists because an ordinary sweep routes every payout through
     * LoongFeeEscrow, and a permissioned quote asset can stop delivering to
     * that one address while still permitting transfers between traders and
     * this curve. Trading then continues normally, but the fees are
     * unreachable, and graduation is unreachable with them: `graduate` sweeps
     * before it hands over the reserves, and fees accrue from the first
     * trade, so the sweep is never a no-op by the time the threshold is
     * crossed. The launch would be stuck on its curve forever.
     *
     * Clearing the buckets here is what unblocks that: the sweep inside
     * `graduate` then finds nothing pending and returns early, so graduation
     * proceeds without this function needing to touch it.
     *
     * The buyback slice is deliberately skipped rather than executed. It
     * would have to settle through the vault and the same escrow, which is
     * the dependency this path exists to route around, so the whole creator
     * bucket is paid out directly instead.
     *
     * Pays the recipients this curve has on record, and both legs in one
     * transaction. An asset that also refuses one of those two addresses
     * defeats this path. `rescueFeesTo` can redirect the immutable protocol
     * recipient immediately. A blocked creator first needs a recipient change
     * through the factory's timelocked owner override (or creator-authorized
     * transfer); the rescue itself always pays the recorded creator.
     *
     * Mirrors LoongMemeHook.rescuePoolFees for the post-graduation pool and
     * LoongLaunchFactory.rescueSweptGraduation for the reserves in between.
     */
    function rescueFees() external onlyFactory nonReentrant returns (uint256 protocolAmount, uint256 creatorAmount) {
        return _rescueFees(protocolFeeRecipient, deployer);
    }

    /**
     * @notice Rescues pending fees to the recorded creator and an owner-chosen
     * protocol recipient when the quote asset refuses the escrow or recorded
     * protocol recipient.
     * @dev The protocol leg may be redirected immediately. An owner change of
     * creator requires the factory's `setCreatorFeeRecipient` proposal and timelocked
     * `executeCreatorFeeRecipientChange`; that execution updates `deployer`.
     * A failed payout is not proof that its recorded recipient is unpayable:
     * another recipient or insufficient callback gas can also cause failure.
     * This entry point therefore never substitutes an unrecorded creator.
     *
     * Payable protocol and creator liabilities are debited before delivery;
     * a failed payout reverts the transaction. Foundation burn funding and any
     * deferred fixed-destination liability remain reserved. A protocol recipient
     * re-entering factory.graduate consequently sees the post-rescue reserve
     * with these protocol and creator liabilities already discharged.
     */
    function rescueFeesTo(address protocolRecipient, address creatorRecipient)
        external
        nonReentrant
        returns (uint256 protocolAmount, uint256 creatorAmount)
    {
        if (msg.sender != Ownable(factory).owner()) revert NotFactoryOwner();
        if (protocolRecipient == address(0) || creatorRecipient == address(0)) revert ZeroAddress();
        if (creatorRecipient != deployer) revert CreatorRecipientChangeRequiresTimelock();
        return _rescueFees(protocolRecipient, creatorRecipient);
    }

    /**
     * @dev Debits payable protocol and creator liabilities before pushing them
     * to the given recipients. Foundation burn funding and any deferred fixed
     * destination remain reserved; a callback cannot spend their backing.
     */
    function _rescueFees(address protocolRecipient, address creatorRecipient)
        private
        returns (uint256 protocolAmount, uint256 creatorAmount)
    {
        if (_foundationFeePolicy.foundationVault != address(0)) {
            return _sweepFoundationFees(0, false, true, protocolRecipient, creatorRecipient);
        }
        uint256 pending = quoteFeeBalance;
        uint256 tax = creatorTaxBalance;
        if (pending == 0 && tax == 0) revert ZeroAmount();

        protocolAmount = (pending * protocolFeeShareBps) / BASIS_POINTS;
        creatorAmount = pending - protocolAmount + tax;

        quoteFeeBalance = 0;
        // Symmetrical with the sweep. This pays the creator their whole
        // bucket, earmark included, so leaving the earmark behind would let a
        // settled claim survive into the next accrual and divert fees the
        // creator has not earned yet into the vest.
        buybackQuoteBalance = 0;
        creatorTaxBalance = 0;
        trackedQuote -= protocolAmount + creatorAmount;

        if (protocolAmount != 0) _sendQuote(protocolRecipient, protocolAmount);
        if (creatorAmount != 0) _sendQuote(creatorRecipient, creatorAmount);

        emit FeesRescued(protocolRecipient, creatorRecipient, protocolAmount, creatorAmount);
    }

    function foundationFeePolicy() external view returns (FoundationFeePolicy memory) {
        return _foundationFeePolicy;
    }

    function setFoundationDestination(bool selected) external onlyFactory {
        if (token != address(0) || _foundationFeePolicy.foundationVault == address(0)) revert InvalidFeePolicy();
        toFoundation = selected;
    }

    /// @notice Retries the exact Foundation allocation against this launch's frozen vault.
    function retryFoundationFees() external nonReentrant {
        if (!toFoundation) revert InvalidFeePolicy();
        _settleFoundationDestination(destinationQuoteBalance);
    }

    /// @dev External only so approval and deposit are one catchable operation.
    function depositFoundationFees(uint256 amount) external payable returns (uint256 received) {
        if (msg.sender != address(this) || !toFoundation) revert InvalidFeePolicy();
        address treasury = _foundationFeePolicy.foundationVault;
        if (isNativeQuote()) {
            return LoongFoundationVault(treasury).deposit{value: amount}(pairToken, amount);
        }
        IERC20(pairToken).forceApprove(treasury, amount);
        return LoongFoundationVault(treasury).deposit(pairToken, amount);
    }

    /// @notice The registered hook pulls retained funding once. Repeated calls return zero.
    function handoffBuyback() external nonReentrant returns (uint256 amount) {
        if (msg.sender != address(feePolicy) || !graduated || _foundationFeePolicy.foundationVault == address(0)) {
            revert InvalidFeePolicy();
        }
        amount = buybackQuoteBalance;
        buybackQuoteBalance = 0;
        quoteFeeBalance -= amount;
        trackedQuote -= amount;
        if (amount != 0) _sendQuote(msg.sender, amount);
    }

    function _sweepFoundationFees(
        uint256 minimum,
        bool execute,
        bool rescue,
        address platformRecipient,
        address creatorRecipient
    ) private returns (uint256 platform, uint256 creator) {
        uint256 destination = destinationQuoteBalance;
        platform = platformQuoteBalance;
        uint256 burnFunding = buybackQuoteBalance;
        creator = quoteFeeBalance - destination - platform - burnFunding;
        uint256 spent;
        uint256 burned;
        // The burn executes up to the price-impact cap and retains only the
        // genuinely unspendable remainder, exactly as the post-graduation hook
        // does with `retainedBuybackQuote`. An all-or-nothing gate would strand
        // the whole bucket whenever accrued funding outgrew the cap, because
        // every other exit stays closed while the curve is ungraduated.
        if (execute && burnFunding != 0) {
            if (minimum == 0) revert MinimumOutputRequired();
            (uint256 qr, uint256 tr) = getReserves();
            // spent * BASIS_POINTS / (qr + spent) <= max  <=>
            // spent <= qr * max / (BASIS_POINTS - max).
            spent = Math.min(
                burnFunding, Math.mulDiv(qr, maxInternalPriceImpactBps, BASIS_POINTS - maxInternalPriceImpactBps)
            );
            if (spent != 0) {
                burned = LoongBondingCurveMath.quoteAmountOut(spent, qr, tr, 0);
                // The burn takes tokens off the same reserve `buy` does, so it
                // answers to the same floor: only the balance above
                // `reservedTokens` is sellable. Clamp the fill down to that
                // instead of dropping it.
                uint256 sellable = sellableTokens();
                if (burned > sellable) {
                    burned = sellable;
                    spent = sellable == 0 ? 0 : Math.min(spent, LoongBondingCurveMath.getAmountIn(sellable, qr, tr, 0));
                }
                if (burned == 0) spent = 0;
                if (spent != 0 && burned < minimum) revert SlippageExceeded(burned, minimum);
            }
        }
        uint256 retainedBurn = burnFunding - spent;
        bool foundation = toFoundation;
        destinationQuoteBalance = foundation ? destination : 0;
        platformQuoteBalance = 0;
        buybackQuoteBalance = retainedBurn;
        quoteFeeBalance = retainedBurn + (foundation ? destination : 0);
        if (!foundation) creator += destination;
        trackedQuote -= platform + creator;
        if (burned != 0) {
            trackedTokens -= burned;
            LoongLauncherToken(token).burn(burned);
            _noteReadiness();
            emit BuybackBurned(spent, burned);
        }
        if (foundation) _settleFoundationDestination(destination);
        if (rescue) {
            if (platform != 0) _sendQuote(platformRecipient, platform);
            if (creator != 0) _sendQuote(creatorRecipient, creator);
        } else {
            if (platform != 0) _creditQuote(platformRecipient, platform);
            if (creator != 0) _creditQuote(creatorRecipient, creator);
        }
        emit FeesSwept(platform, spent, creator);
    }

    function _settleFoundationDestination(uint256 amount) private {
        if (amount == 0) return;
        address treasury = _foundationFeePolicy.foundationVault;
        destinationQuoteBalance -= amount;
        quoteFeeBalance -= amount;
        trackedQuote -= amount;
        uint256 value = isNativeQuote() ? amount : 0;
        try this.depositFoundationFees{value: value}(amount) returns (uint256 received) {
            emit FoundationFeesSwept(token, pairToken, treasury, received);
        } catch {
            destinationQuoteBalance += amount;
            quoteFeeBalance += amount;
            trackedQuote += amount;
            emit FoundationFeesDeferred(token, pairToken, treasury, amount);
        }
    }
}
