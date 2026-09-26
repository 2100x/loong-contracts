// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {LoongLaunchFactory} from "./LoongLaunchFactory.sol";
import {LoongBondingCurve} from "./LoongBondingCurve.sol";
import {IUniversalRouter} from "./SwapAndBuy.sol";

/**
 * @title LaunchAndBuy
 * @notice Launches a token and makes the creator's opening buy in one
 * transaction, so no one can trade the fresh curve between the two.
 * Written to the interface documented for the original router, whose source
 * is not public.
 *
 * The factory must name this contract as its `launchForwarder`; that is what
 * lets the launch be recorded under the real caller (`launchTokenFor`) rather
 * than under this router.
 *
 * Holds nothing between calls. The owner (the Safe on mainnet) can only `rescue` this contract's own
 * balance, i.e. funds sent here by mistake. Every wei or token it
 * receives in a call is either spent on the buy or returned to the caller in
 * the same call.
 */
contract LaunchAndBuy is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // The factory accepts 32 exemptions; the router spends one on the buy recipient.
    uint256 public constant MAX_USER_EXEMPTIONS = 31;

    LoongLaunchFactory public immutable factory;
    /// PancakeSwap's Universal Router: turns the BNB of a `swapLaunchAndBuy` into the coin's pair token.
    IUniversalRouter public immutable universalRouter;

    event Launched(
        address indexed token,
        address indexed curve,
        address indexed recipient,
        address launcher,
        uint256 quoteSpent,
        uint256 tokensReceived
    );

    error ZeroAddress();
    error MinimumOutputRequired();
    error NativeValueMismatch(uint256 supplied, uint256 expected);
    error ExemptionListTooLong();
    error RefundFailed();
    error NativeQuote();
    error InsufficientQuoteOut(uint256 received, uint256 minimum);

    constructor(LoongLaunchFactory factory_, IUniversalRouter universalRouter_, address initialOwner) Ownable(initialOwner) {
        if (address(factory_) == address(0) || address(universalRouter_) == address(0)) revert ZeroAddress();
        factory = factory_;
        universalRouter = universalRouter_;
    }

    // Legacy overloads without the destination flag. Genius's router keeps these for integrations written
    // against its ABI 4.1, so bots and aggregators that already launch on Genius can launch on Loong
    // unchanged. The flag is ignored by the Loong factory anyway (every launch funds the platform-token vault).
    function launchAndBuy(
        LoongLaunchFactory.TokenParams calldata params,
        uint256 configId,
        address pairToken,
        uint256 quoteIn,
        uint256 minimum,
        address recipient
    ) external payable returns (address token, address curve, uint256 tokensOut) {
        return _launchAndBuy(params, configId, pairToken, quoteIn, minimum, recipient, false, new address[](0));
    }

    function launchAndBuy(
        LoongLaunchFactory.TokenParams calldata params,
        uint256 configId,
        address pairToken,
        uint256 quoteIn,
        uint256 minimum,
        address recipient,
        address[] calldata snipeTaxExemptions
    ) external payable returns (address token, address curve, uint256 tokensOut) {
        if (snipeTaxExemptions.length > MAX_USER_EXEMPTIONS) revert ExemptionListTooLong();
        return _launchAndBuy(params, configId, pairToken, quoteIn, minimum, recipient, false, snipeTaxExemptions);
    }

    function launchAndBuy(
        LoongLaunchFactory.TokenParams calldata params,
        uint256 configId,
        address pairToken,
        uint256 quoteIn,
        uint256 minimum,
        address recipient,
        bool toFoundation
    ) external payable returns (address token, address curve, uint256 tokensOut) {
        return _launchAndBuy(params, configId, pairToken, quoteIn, minimum, recipient, toFoundation, new address[](0));
    }

    function launchAndBuy(
        LoongLaunchFactory.TokenParams calldata params,
        uint256 configId,
        address pairToken,
        uint256 quoteIn,
        uint256 minimum,
        address recipient,
        bool toFoundation,
        address[] calldata snipeTaxExemptions
    ) external payable returns (address token, address curve, uint256 tokensOut) {
        if (snipeTaxExemptions.length > MAX_USER_EXEMPTIONS) revert ExemptionListTooLong();
        return _launchAndBuy(params, configId, pairToken, quoteIn, minimum, recipient, toFoundation, snipeTaxExemptions);
    }

    /**
     * @notice Launches a coin quoted in an ERC-20 pair token (a stablecoin or a tokenized stock) and makes the
     * opening buy with plain BNB, all in one transaction: the BNB is swapped into the pair token through the
     * Universal Router (`commands`/`inputs`, built by the caller from a quoted route), the coin is launched for
     * `msg.sender`, and every unit of pair token the swap produced buys the opening position for `recipient`.
     * Neither genius.fun nor flap offers this: both require the creator to hold the pair token already.
     * @dev The route must deliver the pair token to this contract (the router's MSG_SENDER); `minQuoteOut` bounds
     * that leg and `minimum` bounds the curve buy as in `launchAndBuy`. The launch fee is taken from `msg.value`
     * first. Unspent pair token (a buy clamped at the curve's end) and unspent BNB go back to `msg.sender`.
     * `recipient` is always snipe-tax exempt, alongside `snipeTaxExemptions`, exactly as the other entry points.
     */
    function swapLaunchAndBuy(
        LoongLaunchFactory.TokenParams calldata params,
        uint256 configId,
        address pairToken,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline,
        uint256 minQuoteOut,
        uint256 minimum,
        address recipient,
        bool toFoundation,
        address[] calldata snipeTaxExemptions
    ) external payable nonReentrant returns (address token, address curve, uint256 tokensOut) {
        if (pairToken == address(0)) revert NativeQuote(); // a BNB-quoted coin needs no swap: use launchAndBuy
        if (recipient == address(0)) revert ZeroAddress();
        if (minimum == 0) revert MinimumOutputRequired();
        if (snipeTaxExemptions.length > MAX_USER_EXEMPTIONS) revert ExemptionListTooLong();
        uint256 launchFee = factory.launchFee();
        if (msg.value <= launchFee) revert NativeValueMismatch(msg.value, launchFee + 1);
        uint256 bnbBefore = address(this).balance - msg.value;
        IERC20 quote = IERC20(pairToken);
        uint256 quoteBefore = quote.balanceOf(address(this));

        universalRouter.execute{value: msg.value - launchFee}(commands, inputs, deadline);
        uint256 quoteIn = quote.balanceOf(address(this)) - quoteBefore;
        if (quoteIn == 0 || quoteIn < minQuoteOut) revert InsufficientQuoteOut(quoteIn, minQuoteOut);

        address[] memory exemptions = new address[](snipeTaxExemptions.length + 1);
        for (uint256 i = 0; i < snipeTaxExemptions.length; ++i) {
            exemptions[i] = snipeTaxExemptions[i];
        }
        exemptions[snipeTaxExemptions.length] = recipient;
        (token, curve) =
            factory.launchTokenFor{value: launchFee}(params, configId, pairToken, msg.sender, toFoundation, exemptions);

        quote.forceApprove(curve, quoteIn);
        tokensOut = LoongBondingCurve(payable(curve)).buy(quoteIn, minimum, recipient);
        quote.forceApprove(curve, 0);

        uint256 quoteLeft = quote.balanceOf(address(this)) - quoteBefore;
        if (quoteLeft != 0) quote.safeTransfer(msg.sender, quoteLeft);
        uint256 bnbLeft = address(this).balance - bnbBefore;
        if (bnbLeft != 0) {
            (bool ok,) = msg.sender.call{value: bnbLeft}("");
            if (!ok) revert RefundFailed();
        }
        emit Launched(token, curve, recipient, msg.sender, quoteIn - quoteLeft, tokensOut);
    }

    function _launchAndBuy(
        LoongLaunchFactory.TokenParams calldata params,
        uint256 configId,
        address pairToken,
        uint256 quoteIn,
        uint256 minimum,
        address recipient,
        bool toFoundation,
        address[] memory userExemptions
    ) private nonReentrant returns (address token, address curve, uint256 tokensOut) {
        if (recipient == address(0)) revert ZeroAddress();
        // Zero would accept any fill, which in the launch transaction is never what a creator means.
        if (minimum == 0) revert MinimumOutputRequired();

        uint256 launchFee = factory.launchFee();
        bool native = pairToken == address(0);
        uint256 expectedValue = native ? launchFee + quoteIn : launchFee;
        if (msg.value != expectedValue) revert NativeValueMismatch(msg.value, expectedValue);

        // The opening buy lands in the launch second, when the snipe tax peaks,
        // so its recipient must be exempt. The caller is exempt already as
        // originalDeployer.
        address[] memory exemptions = new address[](userExemptions.length + 1);
        for (uint256 i = 0; i < userExemptions.length; ++i) {
            exemptions[i] = userExemptions[i];
        }
        exemptions[userExemptions.length] = recipient;

        (token, curve) = factory.launchTokenFor{value: launchFee}(
            params, configId, pairToken, msg.sender, toFoundation, exemptions
        );

        // Refund = what the clamped final buy of the curve did not spend.
        uint256 spent;
        if (native) {
            uint256 before = address(this).balance;
            tokensOut = LoongBondingCurve(payable(curve)).buy{value: quoteIn}(quoteIn, minimum, recipient);
            uint256 refund = address(this).balance - (before - quoteIn);
            spent = quoteIn - refund;
            if (refund != 0) {
                (bool ok,) = msg.sender.call{value: refund}("");
                if (!ok) revert RefundFailed();
            }
        } else {
            IERC20 quote = IERC20(pairToken);
            quote.safeTransferFrom(msg.sender, address(this), quoteIn);
            quote.forceApprove(curve, quoteIn);
            uint256 before = quote.balanceOf(address(this));
            tokensOut = LoongBondingCurve(payable(curve)).buy(quoteIn, minimum, recipient);
            uint256 refund = quote.balanceOf(address(this)) - (before - quoteIn);
            spent = quoteIn - refund;
            quote.forceApprove(curve, 0);
            if (refund != 0) quote.safeTransfer(msg.sender, refund);
        }

        emit Launched(token, curve, recipient, msg.sender, spent, tokensOut);
    }

    event Rescued(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Returns BNB (`token` = 0) or an ERC-20 that someone sent to this router by mistake.
     * @dev Moves only this contract's OWN balance. It can never touch users' wallets or the allowances
     * they granted this router: the only pulls from users happen inside a launch/buy call, from the
     * caller, for the amount they passed. The router holds nothing between calls, so in normal
     * operation there is nothing to rescue. nonReentrant shares the lock with the trading entrypoints,
     * so it cannot run in the middle of one.
     */
    function rescue(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount;
        if (token == address(0)) {
            amount = address(this).balance;
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert RefundFailed();
        } else {
            amount = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(to, amount);
        }
        emit Rescued(token, to, amount);
    }

    /// @dev Receives the curve's refund of a clamped final buy.
    receive() external payable {}
}
