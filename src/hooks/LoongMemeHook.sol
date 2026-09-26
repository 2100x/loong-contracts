// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Genius. Design derived from PonsV2MemeHook (Pons v2, MIT, hooks/PonsV2MemeHook.sol of the
// verified bundle); rewritten against PancakeSwap Infinity's ICLHooks with conversion and buyback settlement through the Infinity Vault.
// Modifications Copyright (c) 2026 Loong: renamed from Genius; Loong's changes are listed in README.md.
// Original notices above are retained as the licence requires.
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ParametersHelper} from "infinity-core/src/libraries/math/ParametersHelper.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";

import {FoundationFeePolicy, FoundationFeeMath, ILoongFoundationCurve} from "../interfaces/ILoongFoundationFees.sol";
import {LoongFoundationVault} from "../LoongFoundationVault.sol";
import {LoongLauncherToken} from "../LoongLauncherToken.sol";
import {ILoongLaunchFactory, GraduationPhase} from "../interfaces/ILaunchpadV2.sol";
import {LoongBuybackVault} from "../LoongBuybackVault.sol";
import {FeePolicySnapshot, ILoongFeeEscrow, ILoongFeePolicy} from "../interfaces/ILaunchpadV2.sol";

/**
 * @title LoongMemeHook
 * @notice Infinity CL hook and fee-policy oracle for M2 pools. Fees and creator tax accrue in the
 * unspecified swap currency. A trusted operator converts memecoin fees to quote and buys back
 * earmarked fees into the shared vest, with explicit minimum outputs and bounded price movement.
 */
contract LoongMemeHook is ICLHooks, ILockCallback, ILoongFeePolicy, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ParametersHelper for bytes32;
    using CurrencyLibrary for Currency;

    enum SwapDirection {
        MemecoinToQuote,
        QuoteToMemecoin
    }

    struct LaunchInfo {
        bool registered;
        bool memecoinIsCurrency0;
        address memecoin;
        address quoteToken; // address(0) denotes native BNB
        address creator;
        // Initial buyback beneficiary; the factory can redirect the live vault recipient.
        address buybackCreatorRecipient;
        address protocolFeeRecipient;
        uint16 creatorTaxBps;
        uint16 protocolFeeShareBps;
        uint16 buybackBurnBps;
        uint16 hookFeeBps;
        uint16 maxInternalPriceImpactBps;
        bool buybackEnabled;
    }

    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant MAX_PROTOCOL_FEE_SHARE_BPS = 5_000;
    uint256 private constant MAX_HOOK_FEE_BPS = 1_000;
    // Mirrors LoongBondingCurve's own ceiling, so a graduated pool can never charge more per trade than the
    // curve it graduated from.
    uint256 private constant MAX_TOTAL_TRADE_FEE_BPS = 2_000;
    // beforeInitialize (bit 0) | afterSwap (bit 7) | afterSwapReturnsDelta (bit 11), ICLHooks.sol:11-24.
    uint16 private constant HOOKS_REGISTRATION_BITMAP = 0x0881;

    error NotVault();
    error NotFeeSweepOperator();
    error InternalSwapRequiresOperator();
    error MinimumOutputRequired();
    error NotFactory();
    error AlreadySet();
    error OwnershipCannotBeRenounced();
    error ZeroAddress();
    error InvalidBps();
    error AlreadyRegistered();
    error UnknownPool();
    error InvalidPoolKey();
    error SlippageExceeded(uint256 actual, uint256 minimum);
    error InexactQuoteTransfer(address token, uint256 expected, uint256 received);
    error NothingToRescue();
    error NotPoolManager();
    error HookNotImplemented();

    event PoolBuybackSkipped(PoolId indexed poolId, uint256 foldedBackQuote);
    event PoolConversionSkipped(PoolId indexed poolId, uint256 retainedMemecoin);
    // A memecoin bucket the pool consumed for no quote at all, below one unit of quote per swap step.
    event PoolConversionForfeited(PoolId indexed poolId, uint256 forfeitedMemecoin);
    event BuybackVaultSet(address vault);
    event BuybackBurnBpsUpdated(uint256 bps);
    event MaxInternalPriceImpactUpdated(uint256 bps);
    event FeeSweepOperatorUpdated(address operator);
    event BuybackEnabledUpdated(PoolId indexed poolId, bool enabled);
    event FactorySet(address factory);
    event PoolRegistered(PoolId indexed poolId, address memecoin, address quoteToken, address creator);
    event CreatorFeeRecipientUpdated(
        PoolId indexed poolId, address indexed previousRecipient, address indexed newRecipient
    );
    event HookFeeCollected(PoolId indexed poolId, address currency, uint256 feeAmount, uint256 taxAmount);
    event PoolFeesSwept(
        PoolId indexed poolId,
        uint256 protocolAmount,
        uint256 buybackAmount,
        uint256 creatorAmount,
        uint256 tokensLocked
    );
    event PoolFeesRescued(
        PoolId indexed poolId, address indexed quoteToken, uint256 protocolAmount, uint256 creatorAmount
    );
    // Retained ABI declaration from M1. M2 distributions emit quote-denominated PoolFeesSwept.
    event PoolFeesCredited(
        PoolId indexed poolId, address indexed currency, uint256 protocolAmount, uint256 creatorAmount
    );
    event ProtocolFeeShareUpdated(uint256 bps);
    event HookFeeBpsUpdated(uint256 bps);
    event ProtocolFeeRecipientUpdated(address recipient);

    // These public getter names are frozen Pons-compatible ABI elements.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    ICLPoolManager public immutable poolManager;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IVault public immutable vault;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    ILoongFeeEscrow public immutable feeEscrow;

    FoundationFeePolicy private _foundationPolicy;
    /// @dev The vault staged by `setFoundationVault`, held back from
    /// `_foundationPolicy` until `setFoundationFeePolicy` supplies the rates.
    /// A launch freezes whatever regime it reads for its whole life, so the
    /// gap between the two owner calls must publish no Foundation policy at
    /// all rather than one whose four rates are still zero.
    address private _pendingFoundationVault;
    mapping(PoolId => FoundationFeePolicy) private _poolFoundationPolicy;
    mapping(PoolId => bool) private _poolToFoundation;
    mapping(PoolId => address) public poolCurve;
    mapping(PoolId => uint256) public retainedBuybackQuote;
    mapping(address => uint256) public orphanBuybackQuote;
    mapping(address => address) public orphanQuoteAsset;
    event RescuedBuybackCollected(address indexed token, address indexed curve, address indexed asset, uint256 amount);
    mapping(PoolId => mapping(address => uint256)) public pendingDestination;
    mapping(PoolId => mapping(address => uint256)) public pendingPlatform;
    event FoundationFeePolicyUpdated(FoundationFeePolicy previousPolicy, FoundationFeePolicy newPolicy);
    event PoolBuybackBurned(PoolId indexed poolId, uint256 quoteSpent, uint256 tokensBurned);
    event PoolFoundationFeesSwept(
        PoolId indexed poolId, address indexed asset, address indexed foundationVault, uint256 amount
    );
    event PoolFoundationFeesDeferred(
        PoolId indexed poolId, address indexed asset, address indexed foundationVault, uint256 amount
    );
    event GraduatedBuybackCollected(PoolId indexed poolId, address indexed curve, uint256 amount);
    LoongBuybackVault public buybackVault;
    // Deployment sets both from the approved economics before enabling launches.
    uint256 public buybackBurnBps;
    uint256 public maxInternalPriceImpactBps;
    address public factory;
    address public feeSweepOperator;
    address public protocolFeeRecipient;
    uint256 public protocolFeeShareBps;
    uint256 public hookFeeBps;

    mapping(PoolId => LaunchInfo) public launches;
    mapping(PoolId => PoolKey) private _poolKeys;
    mapping(PoolId => mapping(address currency => uint256 amount)) public pendingFees;
    // Creator tax bypasses both the protocol split and buyback.
    mapping(PoolId => mapping(address currency => uint256 amount)) public pendingCreatorTax;

    // An earmark within pendingFees, never an additional asset balance.
    mapping(PoolId => mapping(address currency => uint256 amount)) public pendingBuyback;

    modifier onlyFactory() {
        _checkFactory();
        _;
    }

    modifier poolManagerOnly() {
        _checkPoolManager();
        _;
    }

    function _checkFactory() private view {
        if (msg.sender != factory) revert NotFactory();
    }

    function _checkPoolManager() private view {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    /**
     * @param poolManager_ The PancakeSwap Infinity CLPoolManager of this chain.
     * @param feeEscrow_ Shared claimable balance ledger, also used by every bonding curve.
     * @param protocolFeeRecipient_ Escrow key credited with the protocol's share (also the launch-fee destination).
     * @param protocolFeeShareBps_ Protocol share of every fee bucket, <= 5_000.
     * @param hookFeeBps_ Fee on the unspecified leg of every swap, <= 1_000.
     * @param initialOwner_ Deployer EOA during wiring; transferred to the Safe afterwards (spec 2.9 step 11).
     */
    constructor(
        ICLPoolManager poolManager_,
        ILoongFeeEscrow feeEscrow_,
        address protocolFeeRecipient_,
        uint16 protocolFeeShareBps_,
        uint16 hookFeeBps_,
        address initialOwner_
    ) Ownable(initialOwner_) {
        if (address(poolManager_) == address(0) || address(feeEscrow_) == address(0)) {
            revert ZeroAddress();
        }
        if (protocolFeeRecipient_ == address(0)) revert ZeroAddress();
        if (protocolFeeShareBps_ > MAX_PROTOCOL_FEE_SHARE_BPS || hookFeeBps_ > MAX_HOOK_FEE_BPS) revert InvalidBps();

        poolManager = poolManager_;
        vault = poolManager_.vault();
        feeEscrow = feeEscrow_;
        protocolFeeRecipient = protocolFeeRecipient_;
        protocolFeeShareBps = protocolFeeShareBps_;
        hookFeeBps = hookFeeBps_;
        feeSweepOperator = initialOwner_;

        emit ProtocolFeeShareUpdated(protocolFeeShareBps_);
        emit HookFeeBpsUpdated(hookFeeBps_);
        emit ProtocolFeeRecipientUpdated(protocolFeeRecipient_);
    }

    /**
     * @notice The permissions bitmap Infinity compares with `PoolKey.parameters[0:16)` at `initialize`.
     */
    function getHooksRegistrationBitmap() external pure returns (uint16) {
        return HOOKS_REGISTRATION_BITMAP;
    }

    // ---------------------------------------------------------------------
    // Owner-only configuration (future launches only: the factory snapshots currentFeePolicy() at launch)
    // ---------------------------------------------------------------------

    /**
     * @notice One-time wiring of the factory, set in the deployment run right after the factory is deployed.
     * Owner-gated, so it cannot be front-run (D-45).
     */
    function setFactory(address factory_) external onlyOwner {
        if (factory != address(0)) revert AlreadySet();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    /**
     * @notice Permanently disabled: an ownerless hook could never adjust policy for future launches. Ownership
     * can still be transferred (two-step).
     */
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    function setProtocolFeeShareBps(uint256 bps) external onlyOwner {
        if (bps > MAX_PROTOCOL_FEE_SHARE_BPS) revert InvalidBps();
        protocolFeeShareBps = bps;
        emit ProtocolFeeShareUpdated(bps);
    }

    function setHookFeeBps(uint256 bps) external onlyOwner {
        if (_foundationPolicy.foundationVault != address(0) || bps > MAX_HOOK_FEE_BPS) revert InvalidBps();
        hookFeeBps = bps;
        emit HookFeeBpsUpdated(bps);
    }

    function setProtocolFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientUpdated(recipient);
    }

    // ---------------------------------------------------------------------
    // ILoongFeePolicy
    // ---------------------------------------------------------------------

    /**
     * @notice Returns the policy terms new launches snapshot immutably.
     */
    function currentFeePolicy() external view returns (FeePolicySnapshot memory) {
        return _currentFeePolicy();
    }

    function _currentFeePolicy() private view returns (FeePolicySnapshot memory) {
        return FeePolicySnapshot({
            protocolFeeRecipient: protocolFeeRecipient,
            // Safe: constructor and setter cap the stored value at 5,000.
            // forge-lint: disable-next-line(unsafe-typecast)
            protocolFeeShareBps: uint16(protocolFeeShareBps),
            // Safe: setter caps the stored value at 10,000.
            // forge-lint: disable-next-line(unsafe-typecast)
            buybackBurnBps: uint16(buybackBurnBps),
            // Safe: constructor and setter cap the stored value at 1,000.
            // forge-lint: disable-next-line(unsafe-typecast)
            hookFeeBps: uint16(hookFeeBps),
            // Safe: setter requires a value below 10,000.
            // forge-lint: disable-next-line(unsafe-typecast)
            maxInternalPriceImpactBps: uint16(maxInternalPriceImpactBps)
        });
    }

    // ---------------------------------------------------------------------
    // Factory wiring
    // ---------------------------------------------------------------------

    /**
     * @notice Registers a pool with fee terms frozen at launch by the factory.
     * @dev The factory and this hook share one PoolKey construction rule (spec 2.3): the key must carry this hook,
     * this pool manager and the 0x0881 bitmap, and `memecoin` must be one of its two currencies, because every
     * later fee credit and swap direction is derived from that record. `buybackCreatorRecipient` seeds the shared vault beneficiary.
     */
    function registerPool(
        PoolKey calldata key,
        address memecoin,
        address creator,
        address buybackCreatorRecipient,
        uint16 creatorTaxBps,
        bool buybackEnabled,
        FeePolicySnapshot calldata policy
    ) external onlyFactory {
        PoolId poolId = key.toId();
        if (launches[poolId].registered) revert AlreadyRegistered();
        if (creator == address(0) || buybackCreatorRecipient == address(0)) revert ZeroAddress();
        // Terms frozen here govern the pool for life, so each is held to the same ceiling as the setter that
        // produced it (Pons hooks/PonsV2MemeHook.sol:342-352).
        if (
            policy.protocolFeeRecipient == address(0) || policy.protocolFeeShareBps > MAX_PROTOCOL_FEE_SHARE_BPS
                || policy.buybackBurnBps > BASIS_POINTS || policy.hookFeeBps > MAX_HOOK_FEE_BPS
                || policy.maxInternalPriceImpactBps == 0 || policy.maxInternalPriceImpactBps >= BASIS_POINTS
        ) {
            revert InvalidBps();
        }
        // A pool taking more than the whole unspecified leg would flip the swapper's output delta negative.
        if (uint256(creatorTaxBps) + policy.hookFeeBps > MAX_TOTAL_TRADE_FEE_BPS) revert InvalidBps();

        if (
            address(key.hooks) != address(this) || address(key.poolManager) != address(poolManager)
                || key.parameters.getHooksRegistrationBitmap() != HOOKS_REGISTRATION_BITMAP
        ) {
            revert InvalidPoolKey();
        }
        bool memecoinIsCurrency0 = Currency.unwrap(key.currency0) == memecoin;
        if (!memecoinIsCurrency0 && Currency.unwrap(key.currency1) != memecoin) revert InvalidPoolKey();

        address quoteToken = memecoinIsCurrency0 ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);

        launches[poolId] = LaunchInfo({
            registered: true,
            memecoinIsCurrency0: memecoinIsCurrency0,
            memecoin: memecoin,
            quoteToken: quoteToken,
            creator: creator,
            buybackCreatorRecipient: buybackCreatorRecipient,
            protocolFeeRecipient: policy.protocolFeeRecipient,
            creatorTaxBps: creatorTaxBps,
            protocolFeeShareBps: policy.protocolFeeShareBps,
            buybackBurnBps: policy.buybackBurnBps,
            hookFeeBps: policy.hookFeeBps,
            maxInternalPriceImpactBps: policy.maxInternalPriceImpactBps,
            buybackEnabled: buybackEnabled
        });
        _poolKeys[poolId] = key;
        if (_foundationPolicy.foundationVault != address(0)) {
            address curve = ILoongLaunchFactory(factory).getLaunchedToken(memecoin).curve;
            FoundationFeePolicy memory f = ILoongFoundationCurve(curve).foundationFeePolicy();
            if (f.foundationVault != address(0)) {
                _poolFoundationPolicy[poolId] = f;
                _poolToFoundation[poolId] = ILoongFoundationCurve(curve).toFoundation();
                poolCurve[poolId] = curve;
            }
        }

        emit PoolRegistered(poolId, memecoin, quoteToken, creator);
    }

    /**
     * @notice Updates who receives this pool's creator fee share. Restricted to the factory, which gates both
     * self-service creator transfers and protocol-owner overrides before forwarding here.
     */
    function setCreatorFeeRecipient(PoolId poolId, address newRecipient) external onlyFactory {
        LaunchInfo storage info = launches[poolId];
        if (!info.registered) revert UnknownPool();
        if (newRecipient == address(0)) revert ZeroAddress();

        emit CreatorFeeRecipientUpdated(poolId, info.creator, newRecipient);
        info.creator = newRecipient;
    }

    // ---------------------------------------------------------------------
    // ICLHooks: beforeInitialize and afterSwap are enabled; every other callback reverts HookNotImplemented.
    // All ten are restricted to the pool manager.
    // ---------------------------------------------------------------------

    /**
     * @dev Registration binds a pool id to its memecoin, quote asset and fee recipients, and every later fee
     * credit is derived from that record. Restricting initialization to the factory keeps a pool bearing this
     * hook from existing without one. `sender` is the `msg.sender` of `CLPoolManager.initialize`, so a call
     * through `CLPositionManager.initializePool` is rejected (and swallowed by the position manager).
     */
    function beforeInitialize(address sender, PoolKey calldata, uint160)
        external
        view
        poolManagerOnly
        returns (bytes4)
    {
        if (sender != factory) revert NotFactory();
        return ICLHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external view poolManagerOnly returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view poolManagerOnly returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view poolManagerOnly returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view poolManagerOnly returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view poolManagerOnly returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, ICLPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    /**
     * @notice Takes `hookFeeBps` plus this pool's `creatorTaxBps` of the swap's unspecified currency
     * straight out of the Vault's flash-accounting ledger in a single `take`, crediting the two cuts to separate
     * pending balances. The same amount is returned as the hook delta: CLHooks.afterSwap subtracts it from the
     * swapper's delta and the Vault books it to this hook, so the `take` (-fee) and the return (+fee) net to
     * zero before the swapper's lock closes (spec 2.5). On an exact-output swap the fee is charged on the input
     * leg, which the swapper has not paid yet; `take` draws from the Vault's pooled balance and the swapper
     * settles input plus fee at lock end.
     */
    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external poolManagerOnly returns (bytes4, int128) {
        PoolId poolId = key.toId();
        LaunchInfo memory info = launches[poolId];
        if (!info.registered) return (ICLHooks.afterSwap.selector, 0);
        if (info.hookFeeBps == 0 && info.creatorTaxBps == 0) return (ICLHooks.afterSwap.selector, 0);

        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        (Currency feeCurrency, int128 unspecifiedAmount) =
            specifiedIsCurrency0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;
        if (unspecifiedAmount == 0) return (ICLHooks.afterSwap.selector, 0);

        // Safe: the sign-normalized value is a non-negative int128.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 unspecified = uint256(uint128(unspecifiedAmount));
        uint256 feeAmount = (unspecified * info.hookFeeBps) / BASIS_POINTS;
        uint256 taxAmount = (unspecified * info.creatorTaxBps) / BASIS_POINTS;
        uint256 totalAmount = feeAmount + taxAmount;
        if (totalAmount == 0) return (ICLHooks.afterSwap.selector, 0);

        address feeCurrencyAddr = Currency.unwrap(feeCurrency);
        _takeExact(feeCurrency, feeCurrencyAddr, totalAmount);
        if (feeAmount != 0) {
            pendingFees[poolId][feeCurrencyAddr] += feeAmount;
            if (info.buybackEnabled) {
                if (_poolFoundationPolicy[poolId].foundationVault != address(0)) {
                    (uint256 destination, uint256 platform,, uint256 burnAmount) =
                        FoundationFeeMath.split(feeAmount, _poolFoundationPolicy[poolId]);
                    pendingDestination[poolId][feeCurrencyAddr] += destination;
                    pendingPlatform[poolId][feeCurrencyAddr] += platform;
                    pendingBuyback[poolId][feeCurrencyAddr] += burnAmount;
                } else {
                    uint256 creatorSlice = feeAmount - feeAmount * info.protocolFeeShareBps / BASIS_POINTS;
                    pendingBuyback[poolId][feeCurrencyAddr] += creatorSlice * info.buybackBurnBps / BASIS_POINTS;
                }
            }
        }
        if (taxAmount != 0) pendingCreatorTax[poolId][feeCurrencyAddr] += taxAmount;

        emit HookFeeCollected(poolId, feeCurrencyAddr, feeAmount, taxAmount);
        // totalAmount <= |unspecifiedAmount| which is an int128, so the cast cannot overflow.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (ICLHooks.afterSwap.selector, int128(uint128(totalAmount)));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        poolManagerOnly
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        poolManagerOnly
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /**
     * @dev Records only assets that reached the hook in full. Flash accounting requires exact ERC-20 transfers,
     * so a transfer-tax token fails atomically instead of creating an underfunded fee balance.
     */
    // The before/after balance comparison is the exact-delivery invariant. Only the pool-manager callback reaches
    // this helper, and a mismatch reverts the Vault interaction and all later fee-accounting writes atomically.
    // slither-disable-next-line reentrancy-balance
    function _takeExact(Currency currency, address token, uint256 amount) private {
        if (currency.isNative()) {
            vault.take(currency, address(this), amount);
            return;
        }

        uint256 vaultBalanceBefore = IERC20(token).balanceOf(address(vault));
        uint256 hookBalanceBefore = IERC20(token).balanceOf(address(this));
        vault.take(currency, address(this), amount);
        uint256 vaultBalanceAfter = IERC20(token).balanceOf(address(vault));
        _requireExactDebit(token, vaultBalanceBefore, vaultBalanceAfter, amount);
        uint256 hookBalanceAfter = IERC20(token).balanceOf(address(this));
        uint256 received = hookBalanceAfter >= hookBalanceBefore ? hookBalanceAfter - hookBalanceBefore : 0;
        if (received != amount) revert InexactQuoteTransfer(token, amount, received);
    }

    function _requireExactDebit(address token, uint256 balanceBefore, uint256 balanceAfter, uint256 expected)
        private
        pure
    {
        uint256 debited = balanceAfter <= balanceBefore ? balanceBefore - balanceAfter : 0;
        if (debited != expected) revert InexactQuoteTransfer(token, expected, debited);
    }

    // The before/after balance comparison is the exact-delivery invariant. The nonReentrant sweep has already
    // snapshotted the pool currency buckets, and a mismatch restores pending accounting and escrow effects atomically.
    // slither-disable-next-line reentrancy-balance
    function _payOut(address recipient, address currency, uint256 amount) private {
        if (amount == 0) return;
        if (currency == address(0)) {
            feeEscrow.credit{value: amount}(recipient);
        } else {
            uint256 balanceBefore = IERC20(currency).balanceOf(address(feeEscrow));
            IERC20(currency).forceApprove(address(feeEscrow), amount);
            feeEscrow.creditToken(recipient, currency, amount);
            uint256 received = IERC20(currency).balanceOf(address(feeEscrow)) - balanceBefore;
            if (received != amount) revert InexactQuoteTransfer(currency, amount, received);
        }
    }

    /**
     * @dev Zeroes one currency's pending buckets for a pool and pays the protocol and creator their regular split
     * without the buyback. ERC-20 buckets are pushed directly, bypassing the escrow that stopped accepting them;
     * native buckets are credited to the escrow, the one destination that cannot fail. Returns zero for both legs
     * when nothing is pending.
     */
    function _rescueCurrency(PoolId poolId, LaunchInfo memory info, address currency)
        private
        returns (uint256 protocolAmount, uint256 creatorAmount)
    {
        uint256 total = pendingFees[poolId][currency];
        uint256 tax = pendingCreatorTax[poolId][currency];
        if (total == 0 && tax == 0) return (0, 0);

        pendingFees[poolId][currency] = 0;
        pendingCreatorTax[poolId][currency] = 0;
        // The rescue pays the creator their whole bucket rather than running
        // a buyback, since the swap would fail for the same reason the escrow
        // path did. Clearing the earmark keeps it from surviving as a claim
        // on fees this call has already paid out.
        pendingBuyback[poolId][currency] = 0;

        protocolAmount = (total * info.protocolFeeShareBps) / BASIS_POINTS;
        creatorAmount = total - protocolAmount + tax;

        if (currency == address(0)) {
            // A native escrow credit cannot fail, so the rescue keeps the
            // sweep's own destination and the recipients stay pull-based
            // instead of being pushed at an address that could reject them.
            _payOut(info.protocolFeeRecipient, currency, protocolAmount);
            _payOut(info.creator, currency, creatorAmount);
        } else {
            _sendExact(currency, info.protocolFeeRecipient, protocolAmount);
            _sendExact(currency, info.creator, creatorAmount);
        }

        emit PoolFeesRescued(poolId, currency, protocolAmount, creatorAmount);
    }

    function _sendExact(address token, address recipient, uint256 amount) private {
        if (amount == 0) return;
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(recipient, amount);
        _requireExactDebit(token, balanceBefore, IERC20(token).balanceOf(address(this)), amount);
    }

    function setBuybackVault(LoongBuybackVault buybackVault_) external onlyOwner {
        if (address(buybackVault) != address(0)) revert AlreadySet();
        if (address(buybackVault_) == address(0)) revert ZeroAddress();
        buybackVault = buybackVault_;
        emit BuybackVaultSet(address(buybackVault_));
    }

    function setBuybackBurnBps(uint256 bps) external onlyOwner {
        if (bps > BASIS_POINTS) revert InvalidBps();
        buybackBurnBps = bps;
        emit BuybackBurnBpsUpdated(bps);
    }

    function setMaxInternalPriceImpactBps(uint256 bps) external onlyOwner {
        if (bps == 0 || bps >= BASIS_POINTS) revert InvalidBps();
        maxInternalPriceImpactBps = bps;
        emit MaxInternalPriceImpactUpdated(bps);
    }

    function setFeeSweepOperator(address operator) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        feeSweepOperator = operator;
        emit FeeSweepOperatorUpdated(operator);
    }

    function setBuybackEnabled(PoolId poolId, bool enabled) external onlyFactory {
        LaunchInfo storage info = launches[poolId];
        if (!info.registered) revert UnknownPool();
        if (_poolFoundationPolicy[poolId].foundationVault != address(0) && !enabled) revert InvalidBps();
        info.buybackEnabled = enabled;
        emit BuybackEnabledUpdated(poolId, enabled);
    }

    function sweepPoolFees(PoolId poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut)
        external
        nonReentrant
    {
        LaunchInfo memory info = launches[poolId];
        if (!info.registered) revert UnknownPool();
        bool isOperator = msg.sender == feeSweepOperator;
        if (!isOperator && msg.sender != info.creator) revert NotFeeSweepOperator();
        if (!isOperator && _requiresTrustedOperator(poolId, info)) revert InternalSwapRequiresOperator();

        if (_poolFoundationPolicy[poolId].foundationVault != address(0)) {
            if (!isOperator && retainedBuybackQuote[poolId] != 0) revert InternalSwapRequiresOperator();
            _collectGraduatedBuyback(poolId);
            if (!isOperator && retainedBuybackQuote[poolId] != 0) revert InternalSwapRequiresOperator();
            _sweepFoundationPool(poolId, info, minConversionQuoteOut, minBuybackTokensOut, false);
            return;
        }
        (uint256 convertedFeeQuote, uint256 convertedTaxQuote, uint256 convertedBuybackQuote, bool converted) =
            _convertPendingMemecoin(poolId, info, minConversionQuoteOut);
        // Only a conversion that actually executed is subject to the caller's
        // minimum. Enforcing it when there was nothing to convert, when the
        // swap filled nothing and the pending amount was restored for a later
        // retry, or when a dust bucket was consumed for no quote at all and
        // forfeited to the pool, would block the quote-denominated legs of the
        // sweep over a conversion that never happened.
        uint256 conversionQuoteOut = convertedFeeQuote + convertedTaxQuote;
        if (converted && conversionQuoteOut < minConversionQuoteOut) {
            revert SlippageExceeded(conversionQuoteOut, minConversionQuoteOut);
        }

        uint256 totalQuote = pendingFees[poolId][info.quoteToken] + convertedFeeQuote;
        uint256 taxQuote = pendingCreatorTax[poolId][info.quoteToken] + convertedTaxQuote;
        uint256 buybackQuote = pendingBuyback[poolId][info.quoteToken] + convertedBuybackQuote;
        if (totalQuote == 0 && taxQuote == 0) return;
        pendingFees[poolId][info.quoteToken] = 0;
        pendingCreatorTax[poolId][info.quoteToken] = 0;
        pendingBuyback[poolId][info.quoteToken] = 0;

        _distribute(poolId, info, totalQuote, taxQuote, buybackQuote, minBuybackTokensOut);
    }

    /**
     * @notice Owner-only escape hatch for pending buckets that `sweepPoolFees` can no longer distribute: pays the
     * regular split without the buyback. ERC-20 buckets (a launch token or quote asset that stopped delivering to
     * the escrow exactly) are pushed directly to their recipients; native buckets are credited to the escrow.
     * @dev M1 skipped the native leg because its sweep only ever credited the escrow, which cannot fail for BNB.
     * The M2 sweep swaps through the pool manager before it credits, so a paused `CLPoolManager` (or a pool that
     * can no longer fill) blocks the operator, an outstanding earmark turns the creator away, and a native pool
     * would otherwise have no exit at all. Rescuing native buckets keeps them claimable independently of the pool
     * manager while forfeiting the earmark to the creator, exactly as the ERC-20 rescue does.
     */
    function rescuePoolFees(PoolId poolId)
        external
        onlyOwner
        nonReentrant
        returns (uint256 protocolAmount, uint256 creatorAmount)
    {
        LaunchInfo memory info = launches[poolId];
        if (!info.registered) revert UnknownPool();

        if (_poolFoundationPolicy[poolId].foundationVault != address(0)) {
            _rescueFoundationMemecoin(poolId, info);
            return _sweepFoundationPool(poolId, info, 0, 0, true);
        }
        (protocolAmount, creatorAmount) = _rescueCurrency(poolId, info, info.quoteToken);
        (uint256 memecoinProtocol, uint256 memecoinCreator) = _rescueCurrency(poolId, info, info.memecoin);
        if (protocolAmount == 0 && creatorAmount == 0 && memecoinProtocol == 0 && memecoinCreator == 0) {
            revert NothingToRescue();
        }
    }

    function _requiresTrustedOperator(PoolId poolId, LaunchInfo memory info) private view returns (bool) {
        if (pendingFees[poolId][info.memecoin] != 0 || pendingCreatorTax[poolId][info.memecoin] != 0) {
            return true;
        }

        return pendingBuyback[poolId][info.quoteToken] != 0;
    }

    function _convertPendingMemecoin(PoolId poolId, LaunchInfo memory info, uint256 minConversionQuoteOut)
        private
        returns (uint256 feeQuoteOut, uint256 taxQuoteOut, uint256 buybackQuoteOut, bool converted)
    {
        uint256 feePending = pendingFees[poolId][info.memecoin];
        uint256 taxPending = pendingCreatorTax[poolId][info.memecoin];
        uint256 buybackPending = pendingBuyback[poolId][info.memecoin];
        uint256 totalPending = feePending + taxPending;
        if (totalPending == 0) return (0, 0, 0, false);
        if (minConversionQuoteOut == 0) revert MinimumOutputRequired();

        pendingFees[poolId][info.memecoin] = 0;
        pendingCreatorTax[poolId][info.memecoin] = 0;
        pendingBuyback[poolId][info.memecoin] = 0;
        (uint256 consumed, uint256 quoteOut) = _executeInternalSwap(poolId, SwapDirection.MemecoinToQuote, totalPending);
        if (consumed == 0) {
            pendingFees[poolId][info.memecoin] += feePending;
            pendingCreatorTax[poolId][info.memecoin] += taxPending;
            pendingBuyback[poolId][info.memecoin] += buybackPending;
            emit PoolConversionSkipped(poolId, totalPending);
            return (0, 0, 0, false);
        }
        // Infinity's exact-input step keeps the whole input even when the output
        // rounds down to zero, so a dust bucket comes back as (consumed != 0,
        // quoteOut == 0). That memecoin has already left this hook and is worth
        // less than one unit of quote per swap step, so it is forfeited to the
        // pool rather than restored. Reporting it as not converted keeps the
        // caller's minimum, which can never legally be zero here, from stranding
        // the quote-denominated legs behind a rounding artefact: the same rule
        // the curve applies to a folded-back buyback.
        converted = quoteOut != 0;
        if (!converted) emit PoolConversionForfeited(poolId, consumed);

        uint256 feeConsumed = Math.mulDiv(consumed, feePending, totalPending);
        uint256 taxConsumed = consumed - feeConsumed;
        feeQuoteOut = Math.mulDiv(quoteOut, feeConsumed, consumed);
        taxQuoteOut = quoteOut - feeQuoteOut;

        // The earmark is a marker on part of the fee bucket, so it converts
        // at the fee bucket's own fill ratio and then at the rate that bucket
        // actually realised. feePending is non-zero whenever the earmark is,
        // since the earmark was accrued as a fraction of it.
        if (buybackPending != 0) {
            uint256 buybackConsumed = Math.mulDiv(buybackPending, feeConsumed, feePending);
            buybackQuoteOut = feeConsumed == 0 ? 0 : Math.mulDiv(feeQuoteOut, buybackConsumed, feeConsumed);
            pendingBuyback[poolId][info.memecoin] += buybackPending - buybackConsumed;
        }

        pendingFees[poolId][info.memecoin] += feePending - feeConsumed;
        pendingCreatorTax[poolId][info.memecoin] += taxPending - taxConsumed;
    }

    function _distribute(
        PoolId poolId,
        LaunchInfo memory info,
        uint256 totalQuote,
        uint256 taxQuote,
        uint256 buybackQuote,
        uint256 minBuybackTokensOut
    ) private {
        uint256 protocolAmount = (totalQuote * info.protocolFeeShareBps) / BASIS_POINTS;
        uint256 creatorBucket = totalQuote - protocolAmount;
        // The earmark was summed per swap, so its rounding can land a wei or
        // two above the bucket recomputed here on the aggregate. Clamping
        // keeps the subtraction below sound at a full buyback share, where
        // the two would otherwise be equal.
        uint256 requestedBuyback = buybackQuote < creatorBucket ? buybackQuote : creatorBucket;
        uint256 creatorAmount = creatorBucket - requestedBuyback + taxQuote;

        uint256 buybackSpent;
        uint256 tokensLocked;
        if (requestedBuyback != 0) {
            if (minBuybackTokensOut == 0) revert MinimumOutputRequired();
            (buybackSpent, tokensLocked) = _executeInternalSwap(poolId, SwapDirection.QuoteToMemecoin, requestedBuyback);
            // Return the unfilled quote amount to the creator bucket. The
            // price limit bounds execution without silently retaining value
            // that has already been removed from the creator's accounting.
            creatorAmount += requestedBuyback - buybackSpent;
            if (tokensLocked != 0) {
                uint256 hookBalanceBefore = IERC20(info.memecoin).balanceOf(address(this));
                IERC20(info.memecoin).forceApprove(address(buybackVault), tokensLocked);
                uint256 buybackBalanceBefore = IERC20(info.memecoin).balanceOf(address(buybackVault));
                buybackVault.lock(
                    info.memecoin,
                    tokensLocked,
                    info.buybackCreatorRecipient,
                    info.protocolFeeRecipient,
                    info.protocolFeeShareBps
                );
                _requireExactDebit(
                    info.memecoin, hookBalanceBefore, IERC20(info.memecoin).balanceOf(address(this)), tokensLocked
                );
                uint256 buybackBalanceAfter = IERC20(info.memecoin).balanceOf(address(buybackVault));
                uint256 received =
                    buybackBalanceAfter >= buybackBalanceBefore ? buybackBalanceAfter - buybackBalanceBefore : 0;
                if (received != tokensLocked) revert InexactQuoteTransfer(info.memecoin, tokensLocked, received);
                if (tokensLocked < minBuybackTokensOut) {
                    revert SlippageExceeded(tokensLocked, minBuybackTokensOut);
                }
            } else if (buybackSpent == 0) {
                // Same rule the curve applies: only a buyback that actually
                // executes is subject to the caller's minimum. Enforcing it on
                // a buyback that filled nothing would block the creator and
                // protocol legs too, stranding the whole distribution over a
                // leg that has already been folded back above.
                emit PoolBuybackSkipped(poolId, requestedBuyback);
            } else {
                // Input was consumed but rounded to no output at all. That
                // quote is gone into the pool with nothing locked against it,
                // so it can be neither folded back nor treated as a skip.
                revert SlippageExceeded(0, minBuybackTokensOut);
            }
        }

        _payOut(info.creator, info.quoteToken, creatorAmount);
        _payOut(info.protocolFeeRecipient, info.quoteToken, protocolAmount);

        emit PoolFeesSwept(poolId, protocolAmount, buybackSpent, creatorAmount, tokensLocked);
    }

    function _executeInternalSwap(PoolId poolId, SwapDirection direction, uint256 amountIn)
        private
        returns (uint256 amountInConsumed, uint256 amountOut)
    {
        bytes memory result = vault.lock(abi.encode(poolId, direction, amountIn));
        (amountInConsumed, amountOut) = abi.decode(result, (uint256, uint256));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vault)) revert NotVault();
        (PoolId poolId, SwapDirection direction, uint256 amountIn) = abi.decode(data, (PoolId, SwapDirection, uint256));

        LaunchInfo memory info = launches[poolId];
        PoolKey memory key = _poolKeys[poolId];
        bool zeroForOne =
            direction == SwapDirection.MemecoinToQuote ? info.memecoinIsCurrency0 : !info.memecoinIsCurrency0;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint160 sqrtPriceLimitX96 = _priceLimit(sqrtPriceX96, zeroForOne, info.maxInternalPriceImpactBps);

        // Infinity Hooks.shouldCall skips callbacks only when msg.sender is this registered hook.
        // Keep the swap here: routing it through a helper would collect fees recursively.
        BalanceDelta delta = poolManager.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -SafeCast.toInt256(amountIn),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        _settleCurrency(key.currency0, delta.amount0());
        _settleCurrency(key.currency1, delta.amount1());

        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        uint256 amountInConsumed = inputDelta < 0 ? SafeCast.toUint256(-int256(inputDelta)) : 0;
        uint256 amountOut = outputDelta > 0 ? SafeCast.toUint256(int256(outputDelta)) : 0;
        return abi.encode(amountInConsumed, amountOut);
    }

    function _settleCurrency(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = SafeCast.toUint256(-int256(amount));
            if (currency.isNative()) {
                // Vault.sync carries no lock modifier, so the synced-
                // currency slot is transient state anyone can leave set for
                // the rest of a transaction. Settling native against a stale
                // non-zero slot takes the ERC-20 branch and reverts
                // NonzeroNativeValue, which Infinity calls out as a DoS vector.
                vault.sync(currency);
                vault.settle{value: owed}();
            } else {
                address token = Currency.unwrap(currency);
                uint256 hookBalanceBefore = IERC20(token).balanceOf(address(this));
                uint256 vaultBalanceBefore = IERC20(token).balanceOf(address(vault));
                vault.sync(currency);
                IERC20(token).safeTransfer(address(vault), owed);
                _requireExactDebit(token, hookBalanceBefore, IERC20(token).balanceOf(address(this)), owed);
                uint256 vaultBalanceAfter = IERC20(token).balanceOf(address(vault));
                uint256 received = vaultBalanceAfter >= vaultBalanceBefore ? vaultBalanceAfter - vaultBalanceBefore : 0;
                if (received != owed) revert InexactQuoteTransfer(token, owed, received);
                vault.settle();
            }
        } else if (amount > 0) {
            _takeExact(currency, Currency.unwrap(currency), SafeCast.toUint256(int256(amount)));
        }
    }

    function _priceLimit(uint160 sqrtPriceX96, bool zeroForOne, uint256 maxPriceImpactBps)
        private
        pure
        returns (uint160)
    {
        uint256 factor = BASIS_POINTS - maxPriceImpactBps;
        if (zeroForOne) {
            uint256 limit = (uint256(sqrtPriceX96) * factor) / BASIS_POINTS;
            // forge-lint: disable-next-line(unsafe-typecast)
            return limit <= TickMath.MIN_SQRT_RATIO ? TickMath.MIN_SQRT_RATIO + 1 : uint160(limit);
        } else {
            uint256 limit = (uint256(sqrtPriceX96) * BASIS_POINTS) / factor;
            // casting to uint160 is safe because this branch only runs when limit < TickMath.MAX_SQRT_RATIO, which is itself < type(uint160).max
            // forge-lint: disable-next-line(unsafe-typecast)
            return limit >= TickMath.MAX_SQRT_RATIO ? TickMath.MAX_SQRT_RATIO - 1 : uint160(limit);
        }
    }

    /// @notice Accepts native BNB pulled from the Vault.
    receive() external payable {}

    function setFoundationVault(address treasury) external onlyOwner {
        if (_pendingFoundationVault != address(0)) revert AlreadySet();
        if (treasury == address(0) || LoongFoundationVault(treasury).controller() == address(0)) revert ZeroAddress();
        // Staged, not published: activation is two owner transactions on an
        // already wired stack, and everything a launch reads in between is
        // snapshotted permanently. Leaving both the Foundation policy and the
        // legacy `hookFeeBps` untouched here keeps the previous regime in force
        // for launches in that window, so the atomic rates setter is what
        // actually switches the hook over.
        _pendingFoundationVault = treasury;
    }

    function setFoundationFeePolicy(uint16 destination, uint16 platform, uint16 creator, uint16 burnRate)
        external
        onlyOwner
    {
        FoundationFeePolicy memory next =
            FoundationFeePolicy(destination, platform, creator, burnRate, _pendingFoundationVault);
        uint256 sum = FoundationFeeMath.total(next);
        if (next.foundationVault == address(0) || sum > MAX_HOOK_FEE_BPS) revert InvalidBps();
        emit FoundationFeePolicyUpdated(_foundationPolicy, next);
        _foundationPolicy = next;
        hookFeeBps = sum;
    }

    function currentFoundationFeePolicy() external view returns (FoundationFeePolicy memory) {
        return _foundationPolicy;
    }

    function poolFoundationFeePolicy(PoolId id) external view returns (FoundationFeePolicy memory, bool) {
        return (_poolFoundationPolicy[id], _poolToFoundation[id]);
    }

    /// @dev External only so approval and deposit are one catchable operation.
    function depositPoolFoundationFees(PoolId id, uint256 amount) external payable returns (uint256 received) {
        if (msg.sender != address(this)) revert NotFactory();
        address asset = launches[id].quoteToken;
        address treasury = _poolFoundationPolicy[id].foundationVault;
        if (asset == address(0)) {
            return LoongFoundationVault(treasury).deposit{value: amount}(asset, amount);
        }
        IERC20(asset).forceApprove(treasury, amount);
        return LoongFoundationVault(treasury).deposit(asset, amount);
    }

    function collectGraduatedBuyback(PoolId id) external nonReentrant {
        _collectGraduatedBuyback(id);
    }

    function _collectGraduatedBuyback(PoolId id) private {
        address curve = poolCurve[id];
        if (curve == address(0)) revert UnknownPool();
        address asset = launches[id].quoteToken;
        uint256 beforeBalance = asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        uint256 amount = ILoongFoundationCurve(curve).handoffBuyback();
        uint256 afterBalance = asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        if (afterBalance - beforeBalance != amount) {
            revert InexactQuoteTransfer(asset, amount, afterBalance - beforeBalance);
        }
        retainedBuybackQuote[id] += amount;
        if (amount != 0) emit GraduatedBuybackCollected(id, curve, amount);
    }

    function _sweepFoundationPool(
        PoolId id,
        LaunchInfo memory info,
        uint256 conversionMinimum,
        uint256 burnMinimum,
        bool rescue
    ) private returns (uint256 platform, uint256 creator) {
        uint256 converted;
        uint256 convertedDestination;
        uint256 convertedPlatform;
        uint256 convertedBurn;
        if (!rescue) {
            (converted, convertedDestination, convertedPlatform, convertedBurn) =
                _convertFoundationMemecoin(id, info, conversionMinimum);
        }
        uint256 total = pendingFees[id][info.quoteToken] + converted;
        uint256 destination = pendingDestination[id][info.quoteToken] + convertedDestination;
        platform = pendingPlatform[id][info.quoteToken] + convertedPlatform;
        uint256 burnFunding = pendingBuyback[id][info.quoteToken] + convertedBurn;
        creator = total - destination - platform - burnFunding;
        pendingFees[id][info.quoteToken] = 0;
        pendingDestination[id][info.quoteToken] = 0;
        pendingPlatform[id][info.quoteToken] = 0;
        pendingBuyback[id][info.quoteToken] = 0;
        burnFunding += retainedBuybackQuote[id];
        uint256 spent;
        uint256 burned;
        if (!rescue && burnFunding != 0) {
            if (burnMinimum == 0) revert MinimumOutputRequired();
            (spent, burned) = _executeInternalSwap(id, SwapDirection.QuoteToMemecoin, burnFunding);
            if (spent != 0 && burned < burnMinimum) revert SlippageExceeded(burned, burnMinimum);
            if (burned != 0) {
                LoongLauncherToken(info.memecoin).burn(burned);
                emit PoolBuybackBurned(id, spent, burned);
            }
        }
        retainedBuybackQuote[id] = burnFunding - spent;
        if (_poolToFoundation[id] && destination != 0) {
            _settlePoolFoundationDestination(id, info.quoteToken, destination);
        } else {
            creator += destination;
        }
        if (rescue && info.quoteToken != address(0)) {
            _sendExact(info.quoteToken, info.protocolFeeRecipient, platform);
            _sendExact(info.quoteToken, info.creator, creator);
        } else {
            _payOut(info.protocolFeeRecipient, info.quoteToken, platform);
            _payOut(info.creator, info.quoteToken, creator);
        }
        emit PoolFeesSwept(id, platform, spent, creator, burned);
    }

    /// @dev Convert each liability proportionally to input actually consumed; creator receives unit remainders.
    function _convertFoundationMemecoin(PoolId id, LaunchInfo memory info, uint256 minimum)
        private
        returns (uint256 quote, uint256 destination, uint256 platform, uint256 burnAmount)
    {
        address asset = info.memecoin;
        uint256 pending = pendingFees[id][asset];
        if (pending == 0) return (0, 0, 0, 0);
        if (minimum == 0) revert MinimumOutputRequired();
        uint256 destinationPending = pendingDestination[id][asset];
        uint256 platformPending = pendingPlatform[id][asset];
        uint256 burnPending = pendingBuyback[id][asset];
        (uint256 consumed, uint256 received) = _executeInternalSwap(id, SwapDirection.MemecoinToQuote, pending);
        if (consumed == 0) return (0, 0, 0, 0);
        if (received != 0 && received < minimum) revert SlippageExceeded(received, minimum);
        (uint256 d, uint256 p, uint256 b) =
            FoundationFeeMath.consume(consumed, pending, destinationPending, platformPending, burnPending);
        pendingFees[id][asset] -= consumed;
        pendingDestination[id][asset] -= d;
        pendingPlatform[id][asset] -= p;
        pendingBuyback[id][asset] -= b;
        quote = received;
        (destination, platform, burnAmount) = FoundationFeeMath.consume(received, consumed, d, p, b);
    }

    function _rescueFoundationMemecoin(PoolId id, LaunchInfo memory info) private {
        address asset = info.memecoin;
        uint256 total = pendingFees[id][asset];
        uint256 tax = pendingCreatorTax[id][asset];
        if (total == 0 && tax == 0) return;
        uint256 destination = pendingDestination[id][asset];
        uint256 platform = pendingPlatform[id][asset];
        uint256 burnAmount = pendingBuyback[id][asset];
        uint256 creator = total - destination - platform - burnAmount + tax;
        bool foundation = _poolToFoundation[id];
        if (!foundation) creator += destination;

        pendingFees[id][asset] = burnAmount + (foundation ? destination : 0);
        pendingCreatorTax[id][asset] = 0;
        pendingDestination[id][asset] = foundation ? destination : 0;
        pendingPlatform[id][asset] = 0;
        pendingBuyback[id][asset] = burnAmount;
        _sendExact(asset, info.protocolFeeRecipient, platform);
        _sendExact(asset, info.creator, creator);
        emit PoolFeesRescued(id, asset, platform, creator);
    }

    function _settlePoolFoundationDestination(PoolId id, address asset, uint256 amount) private {
        address treasury = _poolFoundationPolicy[id].foundationVault;
        uint256 value = asset == address(0) ? amount : 0;
        try this.depositPoolFoundationFees{value: value}(id, amount) returns (uint256 received) {
            emit PoolFoundationFeesSwept(id, asset, treasury, received);
        } catch {
            pendingFees[id][asset] += amount;
            pendingDestination[id][asset] += amount;
            emit PoolFoundationFeesDeferred(id, asset, treasury, amount);
        }
    }

    /// @notice Preserves a terminally rescued launch's burn-only funds without granting treasury withdrawal powers.
    /// No executable market exists after rescue: these exceptional liabilities are permanently locked in this release.
    function collectRescuedBuyback(address token) external nonReentrant {
        ILoongLaunchFactory.LaunchedToken memory launch = ILoongLaunchFactory(factory).getLaunchedToken(token);
        if (!launch.exists || launch.phase != GraduationPhase.Rescued) revert UnknownPool();
        FoundationFeePolicy memory f = ILoongFoundationCurve(launch.curve).foundationFeePolicy();
        if (f.foundationVault == address(0)) revert UnknownPool();
        address asset = launch.pairToken;
        uint256 beforeBalance = asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        uint256 amount = ILoongFoundationCurve(launch.curve).handoffBuyback();
        uint256 afterBalance = asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        if (afterBalance - beforeBalance != amount) {
            revert InexactQuoteTransfer(asset, amount, afterBalance - beforeBalance);
        }
        orphanQuoteAsset[token] = asset;
        orphanBuybackQuote[token] += amount;
        if (amount != 0) emit RescuedBuybackCollected(token, launch.curve, asset, amount);
    }
}
