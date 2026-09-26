// SPDX-License-Identifier: GPL-2.0-or-later
// Modifications Copyright (c) 2026 Genius. Derived from PonsV2GraduationGuard (Pons v2, MIT); inlines PancakeSwap
// Infinity's Tick, TickMath and LiquidityAmounts (GPL-2.0-or-later), hence the header (spec 2.10).
// Modifications Copyright (c) 2026 Loong: renamed from Genius; Loong's changes are listed in README.md.
// Original notices above are retained as the licence requires.
pragma solidity ^0.8.26;

import {Tick} from "infinity-core/src/pool-cl/libraries/Tick.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";

import {LoongBondingCurveMath} from "./libraries/LoongBondingCurveMath.sol";
import {LoongGraduationMath} from "./libraries/LoongGraduationMath.sol";

/**
 * @title LoongGraduationGuard
 * @notice Stateless preflight for a graduation's Uniswap V4 seed. It keeps
 * the tick and liquidity math outside LoongLaunchFactory's runtime bytecode
 * while modelling the rejections of the real mint, so a launch can never
 * drain its curve into a seed the PositionManager or V4 core would reject.
 *
 * The preflight has to mirror the whole downstream call graph rather than the
 * PositionManager's ABI field widths alone. Phase one is irreversible: it
 * marks the curve graduated and moves its reserves to the factory, so a seed
 * that passes here and reverts in V4 leaves the launch permanently unseedable
 * and recoverable only through the owner's delayed rescue path.
 */
interface ILoongWiring {
    function launchDeployer() external view returns (address);
    function graduationExecutor() external view returns (address);
    function memeHook() external view returns (address);
    function buybackVault() external view returns (address);
    function locker() external view returns (address);
    function poolManager() external view returns (address);
    function positionManager() external view returns (address);
    function permit2() external view returns (address);
    function feeEscrow() external view returns (address);
    function feePolicy() external view returns (address);
    function factory() external view returns (address);
    function HOOK_BITMAP() external view returns (uint16);
    function getHooksRegistrationBitmap() external view returns (uint16);
}

contract LoongGraduationGuard {
    int24 private constant MIN_USABLE_TICK = -887272;
    int24 private constant MAX_USABLE_TICK = 887272;

    /**
     * @dev V4 carries pool balance changes in a `BalanceDelta` whose halves are
     * `int128`, and `Pool.modifyLiquidity` narrows each side with
     * `SafeCast.toInt128`. The PositionManager's `MINT_POSITION` ABI accepts
     * `uint128`, so an amount in between passes every field-width check and
     * still reverts inside V4 core. The signed bound is the real one.
     */
    uint256 private constant MAX_SEED_AMOUNT = uint256(uint128(type(int128).max));

    error SqrtPriceOutOfBounds();
    error GraduationSeedNotViable();

    /**
     * @notice Computes the initialization price with the same bounds as the seed preflight.
     * @dev Shared with the factory to keep square-root arithmetic outside its EIP-170 budget.
     */
    function sqrtPriceX96FromAmounts(uint256 amount0, uint256 amount1) external pure returns (uint160 sqrtPriceX96) {
        sqrtPriceX96 = LoongGraduationMath.sqrtPriceX96FromAmounts(amount0, amount1);
        if (sqrtPriceX96 <= TickMath.MIN_SQRT_RATIO || sqrtPriceX96 >= TickMath.MAX_SQRT_RATIO) {
            revert SqrtPriceOutOfBounds();
        }
    }

    /**
     * @notice Verifies a launch can initialize and mint a nonzero, full-range
     * V4 position without lossy amount narrowing.
     * @param token Launch token being seeded.
     * @param pairToken Quote asset of the pool; the zero address for native ETH.
     * @param tickSpacing Pool tick spacing the position spans.
     * @param quoteAmount Quote-asset side of the seed.
     * @param tokenAmount Launch-token side of the seed.
     */
    function assertSeedable(
        address token,
        address pairToken,
        int24 tickSpacing,
        uint256 quoteAmount,
        uint256 tokenAmount
    ) external pure {
        if (token == address(0) || quoteAmount > MAX_SEED_AMOUNT || tokenAmount > MAX_SEED_AMOUNT) {
            revert GraduationSeedNotViable();
        }

        // Native ETH sorts below every ERC-20; two ERC-20s sort by address.
        // The seed price is orientation-dependent, so the ordering here must
        // match the PoolKey the factory will build.
        bool quoteIsCurrency0 = pairToken < token;
        (uint256 amount0, uint256 amount1) = quoteIsCurrency0 ? (quoteAmount, tokenAmount) : (tokenAmount, quoteAmount);
        _assertSeedable(tickSpacing, amount0, amount1);
    }

    /**
     * @notice Verifies a seed of these proportions mints under either currency
     * ordering.
     * @dev Launch terms are checked before the launch token exists, so the
     * ordering the PoolKey will use is not yet known. Requiring both is the
     * conservative reading, and the two agree in practice: the sqrt price
     * range is symmetric about 1 and the liquidity formula is invariant under
     * inverting the price and swapping the amounts with it.
     * @param tickSpacing Pool tick spacing the position spans.
     * @param quoteAmount Quote-asset side of the seed.
     * @param tokenAmount Launch-token side of the seed.
     */
    function assertSeedableEitherOrdering(int24 tickSpacing, uint256 quoteAmount, uint256 tokenAmount) external pure {
        if (quoteAmount > MAX_SEED_AMOUNT || tokenAmount > MAX_SEED_AMOUNT) {
            revert GraduationSeedNotViable();
        }
        _assertSeedable(tickSpacing, quoteAmount, tokenAmount);
        _assertSeedable(tickSpacing, tokenAmount, quoteAmount);
    }

    /**
     * @dev Models the price and liquidity rejections of the real mint for one
     * currency ordering. Amount bounds are the caller's to enforce.
     */
    function _assertSeedable(int24 tickSpacing, uint256 amount0, uint256 amount1) private pure {
        uint160 sqrtPriceX96 = LoongGraduationMath.sqrtPriceX96FromAmounts(amount0, amount1);
        if (sqrtPriceX96 <= TickMath.MIN_SQRT_RATIO || sqrtPriceX96 >= TickMath.MAX_SQRT_RATIO) {
            revert SqrtPriceOutOfBounds();
        }

        (int24 tickLower, int24 tickUpper) = _fullRangeTicks(tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount0,
            amount1
        );
        // This mint initializes both boundary ticks, so the position's own
        // liquidity is the entire `liquidityGross` at each of them. V4 reverts
        // with TickLiquidityOverflow once a tick's gross liquidity passes the
        // cap its spacing implies, which is an independent rejection from the
        // amount bounds above.
        if (liquidity == 0 || liquidity > Tick.tickSpacingToMaxLiquidityPerTick(tickSpacing)) {
            revert GraduationSeedNotViable();
        }
    }

    /**
     * @dev Derives V4's usable full-range ticks for the configured spacing.
     */
    function _fullRangeTicks(int24 tickSpacing) private pure returns (int24 tickLower, int24 tickUpper) {
        // Truncation toward zero is required to derive V4's usable boundary ticks.
        // forge-lint: disable-next-line(divide-before-multiply)
        tickLower = (MIN_USABLE_TICK / tickSpacing) * tickSpacing;
        // forge-lint: disable-next-line(divide-before-multiply)
        tickUpper = (MAX_USABLE_TICK / tickSpacing) * tickSpacing;
    }
    error CurveFeeTooHigh();
    error SupplyTooLow();
    error SupplyTooHigh();
    error InvalidPhantomQuote();
    error InvalidGraduationThreshold();
    error InvalidTickSpacing();
    error CoreLpFeeMustBeZero();
    error CurveNotQuotable();

    function validateLaunchTerms(
        uint256 supply,
        uint256 fee,
        uint256 phantom,
        uint256 threshold,
        uint24 poolFee,
        int24 spacing
    ) external pure {
        if (fee > 1_000) revert CurveFeeTooHigh();
        if (supply < 1 ether) revert SupplyTooLow();
        if (supply > MAX_SEED_AMOUNT) revert SupplyTooHigh();
        if (phantom == 0) revert InvalidPhantomQuote();
        if (threshold == 0) revert InvalidGraduationThreshold();
        if (spacing <= 0 || spacing > 32767) revert InvalidTickSpacing();
        if (poolFee != 0) revert CoreLpFeeMustBeZero();
        requireQuotable(phantom, supply, fee);
    }

    function requireQuotable(uint256 phantom, uint256 supply, uint256 fee) public pure {
        if (LoongBondingCurveMath.quoteAmountOut(phantom / 1e6, phantom, supply, fee) == 0) revert CurveNotQuotable();
    }

    error LaunchDependenciesNotWired();

    function requireLaunchDependenciesWired(address factory) external view {
        ILoongWiring f = ILoongWiring(factory);
        ILoongWiring deployer = ILoongWiring(f.launchDeployer());
        ILoongWiring executor = ILoongWiring(f.graduationExecutor());
        ILoongWiring hook = ILoongWiring(f.memeHook());
        ILoongWiring buyback = ILoongWiring(f.buybackVault());
        ILoongWiring locker = ILoongWiring(f.locker());
        if (address(executor) == address(0)) revert LaunchDependenciesNotWired();
        if (
            deployer.factory() != factory || executor.factory() != factory || hook.factory() != factory
                || buyback.factory() != factory || locker.factory() != factory
        ) revert LaunchDependenciesNotWired();
        if (
            hook.buybackVault() != address(buyback) || hook.poolManager() != f.poolManager()
                || hook.feeEscrow() != f.feeEscrow()
        ) revert LaunchDependenciesNotWired();
        if (buyback.feePolicy() != address(hook) || buyback.feeEscrow() != f.feeEscrow()) {
            revert LaunchDependenciesNotWired();
        }
        if (hook.getHooksRegistrationBitmap() != f.HOOK_BITMAP() || locker.positionManager() != f.positionManager()) {
            revert LaunchDependenciesNotWired();
        }
        if (
            executor.positionManager() != f.positionManager() || executor.permit2() != f.permit2()
                || executor.locker() != address(locker)
        ) revert LaunchDependenciesNotWired();
    }
}
