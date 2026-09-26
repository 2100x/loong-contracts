// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {LoongLaunchFactory} from "./LoongLaunchFactory.sol";
import {LoongBondingCurve} from "./LoongBondingCurve.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @title SwapAndBuy
 * @notice Lets a wallet holding only BNB buy a curve quoted in an ERC-20
 * (USDT, a tokenized stock...) in one transaction: BNB -> quote asset through
 * PancakeSwap's UniversalRouter, then the whole proceeds into the curve.
 *
 * The swap route is built off-chain (the frontend quotes it) and passed in as
 * UniversalRouter commands. That is safe here because this contract only ever
 * pays with the BNB attached to the call: it grants the UniversalRouter no
 * token allowance and holds no balance between calls, so a hostile route can
 * at worst waste the caller's own BNB, and the `minQuoteOut`/`minTokensOut`
 * bounds catch that.
 *
 * The owner (the Safe on mainnet) can only `rescue` this contract's own balance, i.e. funds sent here
 * by mistake; it has no power over callers' wallets or allowances.
 */
contract SwapAndBuy is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    LoongLaunchFactory public immutable factory;
    IUniversalRouter public immutable universalRouter;

    event SwappedAndBought(
        address indexed token, address indexed buyer, address indexed recipient, uint256 bnbIn, uint256 quoteIn, uint256 tokensOut
    );

    error ZeroAddress();
    error UnknownToken();
    error NativeQuote();
    error InsufficientQuoteOut(uint256 received, uint256 minimum);
    error RefundFailed();
    error InsufficientNativeOut(uint256 received, uint256 minimum);

    constructor(LoongLaunchFactory factory_, IUniversalRouter universalRouter_, address initialOwner) Ownable(initialOwner) {
        if (address(factory_) == address(0) || address(universalRouter_) == address(0)) revert ZeroAddress();
        factory = factory_;
        universalRouter = universalRouter_;
    }

    /**
     * @param token The launch token to buy (must be on its curve).
     * @param commands,inputs UniversalRouter program that turns msg.value BNB
     * into the curve's quote asset, delivered to this contract.
     * @param minQuoteOut Floor on the quote asset the swap must deliver.
     * @param minTokensOut Floor on the launch tokens the curve must deliver.
     */
    function swapAndBuy(
        address token,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline,
        uint256 minQuoteOut,
        uint256 minTokensOut,
        address recipient
    ) external payable nonReentrant returns (uint256 tokensOut) {
        if (recipient == address(0)) revert ZeroAddress();
        LoongLaunchFactory.LaunchedToken memory launch = factory.getLaunchedToken(token);
        if (!launch.exists) revert UnknownToken();
        if (launch.pairToken == address(0)) revert NativeQuote(); // buy the curve directly

        IERC20 quote = IERC20(launch.pairToken);
        uint256 bnbBefore = address(this).balance - msg.value;
        uint256 quoteBefore = quote.balanceOf(address(this));

        universalRouter.execute{value: msg.value}(commands, inputs, deadline);

        uint256 quoteIn = quote.balanceOf(address(this)) - quoteBefore;
        if (quoteIn < minQuoteOut || quoteIn == 0) revert InsufficientQuoteOut(quoteIn, minQuoteOut);

        quote.forceApprove(launch.curve, quoteIn);
        tokensOut = LoongBondingCurve(payable(launch.curve)).buy(quoteIn, minTokensOut, recipient);
        quote.forceApprove(launch.curve, 0);

        // Anything not consumed goes back: a clamped final curve buy refunds
        // quote asset, and a route may leave BNB unspent.
        uint256 quoteLeft = quote.balanceOf(address(this)) - quoteBefore;
        if (quoteLeft != 0) quote.safeTransfer(msg.sender, quoteLeft);
        uint256 bnbLeft = address(this).balance - bnbBefore;
        if (bnbLeft != 0) {
            (bool ok,) = msg.sender.call{value: bnbLeft}("");
            if (!ok) revert RefundFailed();
        }

        emit SwappedAndBought(token, msg.sender, recipient, msg.value - bnbLeft, quoteIn - quoteLeft, tokensOut);
    }

    event SoldAndSwapped(
        address indexed token, address indexed seller, address indexed recipient, uint256 tokensIn, uint256 quoteOut, uint256 bnbOut
    );

    /**
     * @notice The mirror of `swapAndBuy`: sells a pair-token coin on its curve and pays the proceeds out in BNB, in
     * one transaction. The coin is pulled from `msg.sender` (approve this contract first), sold on the curve with
     * this contract as recipient, the pair token is handed to the Universal Router, and `commands`/`inputs` (built
     * by the caller from a quoted route ending in UNWRAP_WETH to MSG_SENDER) turn it into BNB for `recipient`.
     * genius.fun pays such sells out only in the pair token.
     * @dev `minQuoteOut` bounds the curve sell, `minBnbOut` the whole trade. Any pair token the route leaves
     * behind (it should leave none) is returned to `msg.sender`. Only for coins still on their curve: after
     * graduation the Universal Router does the whole sell -> swap -> unwrap by itself.
     */
    function sellAndSwap(
        address token,
        uint256 tokensIn,
        uint256 minQuoteOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline,
        uint256 minBnbOut,
        address recipient
    ) external nonReentrant returns (uint256 bnbOut) {
        if (recipient == address(0)) revert ZeroAddress();
        LoongLaunchFactory.LaunchedToken memory launch = factory.getLaunchedToken(token);
        if (!launch.exists) revert UnknownToken();
        if (launch.pairToken == address(0)) revert NativeQuote(); // sell the curve directly
        IERC20 quote = IERC20(launch.pairToken);
        uint256 quoteBefore = quote.balanceOf(address(this));
        uint256 bnbBefore = address(this).balance;

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);
        IERC20(token).forceApprove(launch.curve, tokensIn);
        uint256 quoteOut = LoongBondingCurve(payable(launch.curve)).sell(tokensIn, minQuoteOut, address(this));
        IERC20(token).forceApprove(launch.curve, 0);

        quote.safeTransfer(address(universalRouter), quoteOut);
        universalRouter.execute(commands, inputs, deadline);

        bnbOut = address(this).balance - bnbBefore;
        if (bnbOut < minBnbOut || bnbOut == 0) revert InsufficientNativeOut(bnbOut, minBnbOut);
        (bool ok,) = recipient.call{value: bnbOut}("");
        if (!ok) revert RefundFailed();
        uint256 quoteLeft = quote.balanceOf(address(this)) - quoteBefore;
        if (quoteLeft != 0) quote.safeTransfer(msg.sender, quoteLeft);
        emit SoldAndSwapped(token, msg.sender, recipient, tokensIn, quoteOut, bnbOut);
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

    receive() external payable {}
}
