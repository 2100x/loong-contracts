// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ForkLifecycleTest} from "./ForkLifecycle.t.sol";
import {LoongBondingCurve} from "../src/LoongBondingCurve.sol";
import {LoongBuybackBurner, IFoundationVault, IUniversalRouterLike} from "../src/LoongBuybackBurner.sol";
import {GraduationPhase} from "../src/interfaces/ILaunchpadV2.sol";

/// $LOONG buyback-and-burn on a BSC mainnet fork: the burner is the foundation vault's controller from birth.
/// Run: forge test --match-contract BuybackBurnerTest --match-test Burner
contract BuybackBurnerTest is ForkLifecycleTest {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address keeper = makeAddr("keeper");
    address poker = makeAddr("poker");
    LoongBuybackBurner burner;

    function _p() internal pure returns (LoongBuybackBurner.Params memory) {
        return LoongBuybackBurner.Params({
            chunk: 0.05 ether,
            minBuy: 0.01 ether,
            minInterval: 900,
            tip: 0.0005 ether,
            maxDeviationBps: 300,
            driftBpsPerHour: 1200,
            launchDelay: 60,
            openAccess: true
        });
    }

    function _foundationController() internal override returns (address) {
        LoongBuybackBurner impl = new LoongBuybackBurner();
        bytes memory init = abi.encodeCall(
            LoongBuybackBurner.initialize, (owner, keeper, factory, IUniversalRouterLike(UR), WBNB, _p())
        );
        burner = LoongBuybackBurner(payable(address(new ERC1967Proxy(address(impl), init))));
        return address(burner);
    }

    function _setupLoong() internal returns (address token, LoongBondingCurve curve) {
        (token, curve) = _launch("LOONG", address(0));
        vm.startPrank(owner);
        burner.setVault(IFoundationVault(address(foundation)));
        burner.setLoong(token);
        burner.setPaused(false);
        vm.stopPrank();
    }

    function test_Burner_VaultControllerIsBurner() public view {
        assertEq(foundation.controller(), address(burner));
        assertEq(burner.owner(), owner);
        assertTrue(burner.isKeeper(keeper));
    }

    function test_Burner_CurveThenPool() public {
        (address token, LoongBondingCurve curve) = _setupLoong();
        // Curve fees reach the vault when the keeper sweeps them (test_FeeSplit_* cover that path); here the vault
        // is simply funded as if two sweeps had happened.
        vm.deal(address(foundation), 2 ether);

        // Too early: the snipe-tax window must be over, and status() says when (a keeper polls it).
        (uint256 nextAt,,) = burner.status();
        assertEq(nextAt, curve.launchedAt() + 60, "status must include the launch delay");
        vm.expectRevert(abi.encodeWithSelector(LoongBuybackBurner.TooSoon.selector, nextAt));
        vm.prank(poker);
        burner.poke();

        vm.warp(block.timestamp + 61);
        uint256 dead0 = IERC20(token).balanceOf(DEAD);
        uint256 pb = poker.balance;
        vm.prank(poker);
        uint256 burned = burner.poke();
        assertGt(burned, 0, "nothing burned");
        assertEq(IERC20(token).balanceOf(DEAD) - dead0, burned, "not at 0xdead");
        assertEq(IERC20(token).balanceOf(address(burner)), 0, "burner kept LOONG");
        assertEq(poker.balance - pb, 0.0005 ether, "tip");
        assertEq(address(foundation).balance, 0, "vault BNB not pulled");
        assertEq(burner.totalBnbSpent(), 0.05 ether, "chunk");
        console2.log("curve poke: 0.05 BNB burned LOONG", burned / 1e18);

        // Rate limit.
        vm.expectRevert();
        vm.prank(poker);
        burner.poke();

        // Someone pumps right before a poke: the guard refuses (curve price jumps far beyond 3%).
        vm.warp(block.timestamp + 900);
        vm.prank(whale);
        curve.buy{value: 3 ether}(3 ether, 1, whale);
        vm.expectRevert();
        vm.prank(poker);
        burner.poke();

        // The keeper re-anchors after a real move; the next poke goes through.
        vm.prank(keeper);
        burner.resetReference();
        vm.prank(poker);
        assertGt(burner.poke(), 0);

        // Graduate $LOONG, then the burner buys in its Infinity pool.
        vm.prank(whale);
        curve.buy{value: 30 ether}(30 ether, 1, whale);
        factory.createGraduatedPool(token);
        assertEq(uint8(factory.getLaunchedToken(token).phase), uint8(GraduationPhase.PoolCreated));
        vm.warp(block.timestamp + 900);
        // No manual reset: the first pool buy re-anchors by itself after graduation.
        uint256 d1 = IERC20(token).balanceOf(DEAD);
        vm.prank(poker);
        uint256 burnedPool = burner.poke();
        assertGt(burnedPool, 0, "pool buy burned nothing");
        assertEq(IERC20(token).balanceOf(DEAD) - d1, burnedPool);
        console2.log("pool poke: 0.05 BNB burned LOONG", burnedPool / 1e18);

        // Our own buys move the price too; at this chunk several pokes in a row must stay inside the band.
        for (uint256 i; i < 8; ++i) {
            vm.warp(block.timestamp + 900);
            vm.prank(poker);
            assertGt(burner.poke(), 0);
        }
        assertEq(IERC20(token).balanceOf(address(burner)), 0);
        console2.log("total BNB spent", burner.totalBnbSpent(), "total LOONG burned", burner.totalBurned() / 1e18);
    }

    function test_Burner_ConvertUSDT() public {
        _setupLoong();
        deal(USDT, address(foundation), 500 ether);
        LoongBuybackBurner.Leg[] memory legs = new LoongBuybackBurner.Leg[](1);
        legs[0] = LoongBuybackBurner.Leg({v2: false, path: abi.encodePacked(USDT, uint24(100), WBNB)});
        vm.prank(owner);
        burner.setRoute(USDT, legs);

        // Only keeper/owner may convert, and the route is fixed by the owner.
        vm.expectRevert(LoongBuybackBurner.NotKeeper.selector);
        vm.prank(poker);
        burner.convert(USDT, 0, 0);

        vm.prank(keeper);
        uint256 bnb = burner.convert(USDT, 0, 0.1 ether);
        console2.log("500 USDT -> BNB wei", bnb);
        assertGt(bnb, 0.1 ether);
        assertEq(IERC20(USDT).balanceOf(address(foundation)), 0);
        assertEq(IERC20(USDT).balanceOf(address(burner)), 0);
        assertEq(address(burner).balance, bnb + 1, "plus the vault's 1 wei construction probe");

        // A too-high minimum reverts and nothing moves.
        deal(USDT, address(foundation), 10 ether);
        vm.expectRevert();
        vm.prank(keeper);
        burner.convert(USDT, 0, 10 ether);
        assertEq(IERC20(USDT).balanceOf(address(foundation)), 10 ether);
    }

    function test_Burner_RouteValidation() public {
        LoongBuybackBurner.Leg[] memory legs = new LoongBuybackBurner.Leg[](1);
        // Does not end in WBNB.
        legs[0] = LoongBuybackBurner.Leg({v2: false, path: abi.encodePacked(USDT, uint24(100), address(0xBEEF))});
        vm.expectRevert(LoongBuybackBurner.BadRoute.selector);
        vm.prank(owner);
        burner.setRoute(USDT, legs);
        // Does not start at the asset.
        legs[0] = LoongBuybackBurner.Leg({v2: false, path: abi.encodePacked(address(0xBEEF), uint24(100), WBNB)});
        vm.expectRevert(LoongBuybackBurner.BadRoute.selector);
        vm.prank(owner);
        burner.setRoute(USDT, legs);
        // V2 leg accepted.
        address[] memory v2 = new address[](2);
        v2[0] = USDT;
        v2[1] = WBNB;
        legs[0] = LoongBuybackBurner.Leg({v2: true, path: abi.encode(v2)});
        vm.prank(owner);
        burner.setRoute(USDT, legs);
        assertEq(burner.route(USDT).length, 1);
    }

    function test_Burner_OwnerPowers() public {
        _setupLoong();
        vm.deal(address(foundation), 1 ether);
        // Not owner.
        vm.expectRevert(LoongBuybackBurner.NotOwner.selector);
        vm.prank(keeper);
        burner.withdraw(address(0), 1 ether, keeper, true);
        address evil = address(new LoongBuybackBurner()); // built first: expectRevert would bind to `new`
        vm.expectRevert(LoongBuybackBurner.NotOwner.selector);
        vm.prank(keeper);
        burner.upgradeToAndCall(evil, "");
        // Owner can withdraw from the vault through the burner ("flexible like Pons").
        address safe2 = makeAddr("safe2");
        vm.prank(owner);
        burner.withdraw(address(0), 1 ether, safe2, true);
        assertEq(safe2.balance, 1 ether);
        // Owner can upgrade; state survives.
        address tokenBefore = burner.loong();
        LoongBuybackBurner impl2 = new LoongBuybackBurner();
        vm.prank(owner);
        burner.upgradeToAndCall(address(impl2), "");
        assertEq(burner.loong(), tokenBefore);
        // setLoong refuses a coin that is not BNB-paired.
        (address usdtCoin,) = _launch("USDTCOIN", USDT);
        vm.expectRevert(LoongBuybackBurner.NotBnbPaired.selector);
        vm.prank(owner);
        burner.setLoong(usdtCoin);
        // Two-step ownership handover.
        vm.prank(owner);
        burner.transferOwnership(safe2);
        vm.prank(safe2);
        burner.acceptOwnership();
        assertEq(burner.owner(), safe2);
        // Implementation cannot be initialized by anyone.
        vm.expectRevert();
        impl2.initialize(poker, poker, factory, IUniversalRouterLike(UR), WBNB, _p());
    }

    function test_Burner_StartsPausedAndSwitch() public {
        (address token,) = _launch("LOONG", address(0));
        vm.deal(address(foundation), 1 ether);
        assertTrue(burner.paused(), "must start paused");
        vm.startPrank(owner);
        burner.setVault(IFoundationVault(address(foundation)));
        burner.setLoong(token);
        vm.stopPrank();
        vm.warp(block.timestamp + 120);
        // Paused: nobody can buy or convert, fees stay in the vault.
        vm.expectRevert(LoongBuybackBurner.IsPaused.selector);
        vm.prank(poker);
        burner.poke();
        vm.expectRevert(LoongBuybackBurner.IsPaused.selector);
        vm.prank(keeper);
        burner.convert(USDT, 0, 0);
        assertEq(address(foundation).balance, 1 ether, "vault untouched while paused");
        // Only the owner resumes.
        vm.expectRevert(LoongBuybackBurner.NotOwner.selector);
        vm.prank(keeper);
        burner.setPaused(false);
        vm.prank(owner);
        burner.setPaused(false);
        vm.prank(poker);
        assertGt(burner.poke(), 0);
        // The keeper can pause in an emergency; a stranger cannot.
        vm.expectRevert(LoongBuybackBurner.NotKeeper.selector);
        vm.prank(poker);
        burner.setPaused(true);
        vm.prank(keeper);
        burner.setPaused(true);
        vm.warp(block.timestamp + 900);
        vm.expectRevert(LoongBuybackBurner.IsPaused.selector);
        vm.prank(poker);
        burner.poke();
        // Owner can still withdraw while paused.
        address safe2 = makeAddr("safe2");
        uint256 left = address(foundation).balance;
        vm.prank(owner);
        burner.withdraw(address(0), left, safe2, true);
        assertEq(safe2.balance, left);
    }

    function test_Burner_ClosedAccess() public {
        _setupLoong();
        vm.deal(address(foundation), 1 ether);
        LoongBuybackBurner.Params memory p = _p();
        p.openAccess = false;
        vm.prank(owner);
        burner.setParams(p);
        vm.warp(block.timestamp + 120);
        vm.expectRevert(LoongBuybackBurner.NotKeeper.selector);
        vm.prank(poker);
        burner.poke();
        vm.prank(keeper);
        assertGt(burner.poke(), 0);
    }
}
