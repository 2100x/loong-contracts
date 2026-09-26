// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {LoongLaunchFactory} from "../src/LoongLaunchFactory.sol";
import {LoongBondingCurve} from "../src/LoongBondingCurve.sol";
import {LoongLauncherToken} from "../src/LoongLauncherToken.sol";
import {LoongLaunchLocker} from "../src/LoongLaunchLocker.sol";
import {LoongBuybackVault} from "../src/LoongBuybackVault.sol";
import {LoongLaunchDeployer, LaunchDeployment} from "../src/LoongLaunchDeployer.sol";
import {LoongGraduationExecutor} from "../src/LoongGraduationExecutor.sol";
import {LoongFoundationVault} from "../src/LoongFoundationVault.sol";
import {LoongMemeHook} from "../src/hooks/LoongMemeHook.sol";
import {ILoongMemeHook} from "../src/interfaces/ILoongMemeHook.sol";
import {ILoongFeeEscrow, ILoongFeePolicy, GraduationPhase} from "../src/interfaces/ILaunchpadV2.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {LaunchAndBuy} from "../src/LaunchAndBuy.sol";
import {SwapAndBuy, IUniversalRouter} from "../src/SwapAndBuy.sol";

/// Minimal Infinity swapper for tests: exact-input swap through the vault lock.
contract InfinitySwapper {
    IVault public immutable vault;
    ICLPoolManager public immutable pm;

    constructor(IVault v, ICLPoolManager p) {
        vault = v;
        pm = p;
    }

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) external payable returns (uint256 out) {
        Currency cin = zeroForOne ? key.currency0 : key.currency1;
        if (!cin.isNative()) IERC20(Currency.unwrap(cin)).transferFrom(msg.sender, address(this), amountIn);
        out = abi.decode(vault.lock(abi.encode(key, zeroForOne, amountIn, msg.sender)), (uint256));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(vault), "vault");
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, address to) =
            abi.decode(data, (PoolKey, bool, uint256, address));
        BalanceDelta d = pm.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            ""
        );
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        _settle(key.currency0, a0, to);
        _settle(key.currency1, a1, to);
        int128 outD = zeroForOne ? a1 : a0;
        return abi.encode(uint256(int256(outD)));
    }

    function _settle(Currency c, int128 amt, address to) private {
        if (amt < 0) {
            uint256 owed = uint256(-int256(amt));
            vault.sync(c);
            if (c.isNative()) {
                vault.settle{value: owed}();
            } else {
                IERC20(Currency.unwrap(c)).transfer(address(vault), owed);
                vault.settle();
            }
        } else if (amt > 0) {
            vault.take(c, to, uint256(int256(amt)));
        }
    }

    receive() external payable {}
}

contract ForkLifecycleTest is Test {
    // PancakeSwap Infinity on BSC mainnet (from Genius's pinned manifest).
    IVault constant VAULT = IVault(0x238a358808379702088667322f80aC48bAd5e6c4);
    ICLPoolManager constant PM = ICLPoolManager(0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b);
    ICLPositionManager constant POSM = ICLPositionManager(0x55f4c8abA71A1e923edC303eb4fEfF14608cC226);
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768);
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    address owner = makeAddr("owner");
    address protocol = makeAddr("protocol");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address whale = makeAddr("whale");

    FeeEscrow escrow;
    LoongMemeHook hook;
    LoongLaunchLocker locker;
    LoongBuybackVault buyback;
    LoongLaunchFactory factory;
    LoongFoundationVault foundation;
    InfinitySwapper swapper;
    LaunchAndBuy router;

    function setUp() public {
        vm.createSelectFork(vm.envString("BSC_RPC"), 123_530_000);
        vm.deal(owner, 10 ether);
        vm.startPrank(owner);

        escrow = new FeeEscrow();
        hook = new LoongMemeHook(PM, ILoongFeeEscrow(address(escrow)), protocol, 3000, 100, owner);
        locker = new LoongLaunchLocker(owner, address(POSM));
        buyback = new LoongBuybackVault(owner, hook, ILoongFeeEscrow(address(escrow)));
        factory = new LoongLaunchFactory(
            owner,
            PM,
            POSM,
            PERMIT2,
            locker,
            ILoongMemeHook(address(hook)),
            ILoongFeeEscrow(address(escrow)),
            buyback,
            0 // Loong charges no launch fee
        );
        hook.setFactory(address(factory));
        locker.setFactory(address(factory));
        buyback.setFactory(address(factory));
        hook.setBuybackVault(buyback);
        hook.setBuybackBurnBps(5000);
        hook.setMaxInternalPriceImpactBps(300);
        factory.setLaunchDeployer(new LoongLaunchDeployer(address(factory)));
        factory.setGraduationExecutor(new LoongGraduationExecutor(POSM, PERMIT2, locker, address(factory)));
        factory.addLaunchConfig(
            LoongLaunchFactory.LaunchConfig({
                supply: 1_000_000_000 ether,
                curveFeeBps: 100, // Loong: 1% per trade
                // Loong: 4.8 BNB start / 12 BNB graduation (config/economics.mainnet.json).
                phantomQuote: 4.8 ether,
                graduationThreshold: 12 ether,
                poolFee: 0,
                tickSpacing: 200,
                enabled: true
            })
        );
        factory.setSnipeTaxStartBps(9900);
        factory.setSnipeTaxSeconds(3); // Loong: 3s window (Genius runs 15s)

        // Loong's 1% split: creator 0.70% / platform 0.10% / this coin's buyback-and-burn 0.10% /
        // platform-token buyback 0.10%. The last one rides Loong's "destination" leg into the vault, which the
        // factory now forces on for every launch.
        // Runs on Genius's explicit-split ("Foundation") regime with the destination leg zeroed, because
        // that regime burns its buyback; the legacy regime locks it into a vest instead.
        foundation = new LoongFoundationVault{value: 1}(_foundationController());
        hook.setFoundationVault(address(foundation));
        hook.setFoundationFeePolicy(10, 10, 70, 10);

        // USDT as an ERC-20 quote asset, $4k phantom / $10k threshold like mainnet.
        factory.setPairTokenEconomics(USDT, 4000 ether, 10_000 ether, 18);
        factory.setPairTokenApproved(USDT, true);

        router = new LaunchAndBuy(factory, IUniversalRouter(0xd9C500DfF816a1Da21A48A732d3498Bf09dc9AEB), owner);
        factory.setLaunchForwarder(address(router));

        factory.setLaunchEnabled(true);
        vm.stopPrank();

        swapper = new InfinitySwapper(VAULT, PM);
        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(whale, 100 ether);
    }

    function _params(string memory sym) internal view returns (LoongLaunchFactory.TokenParams memory p) {
        p.name = string.concat(sym, " coin");
        p.symbol = sym;
        p.creatorFeeRecipient = creator;
        p.buybackEnabled = true;
        p.salt = keccak256(bytes(sym));
    }

    /// Mines a CREATE2 salt that lands the token on a ...9999 address, mirroring LoongLaunchDeployer exactly.
    /// The curve's init code does not depend on the salt, so its hash is computed once; the token's init code
    /// embeds the curve address, which is patched in place each round (7th head word of the constructor args).
    function _mine(LoongLaunchFactory.TokenParams memory p, address pairToken, address launcher)
        internal
        view
        returns (bytes32)
    {
        LaunchDeployment memory d = _deployment(p, pairToken, launcher);
        bytes32 curveHash = _curveHash(d);
        bytes memory init = abi.encodePacked(
            type(LoongLauncherToken).creationCode,
            abi.encode(d.name, d.symbol, d.logo, d.description, d.socials, launcher, address(0), address(factory), d.supply)
        );
        address deployer = address(factory.launchDeployer());
        uint256 slot = init.length - _argsLength(d) + 6 * 32;
        _checkDerivation(d, curveHash, init, deployer, slot);
        for (uint256 i = 1; ; ++i) {
            if (uint16(uint160(_tokenAt(launcher, bytes32(i), curveHash, init, deployer, slot))) == 0x9999) {
                return bytes32(i);
            }
        }
    }

    function _deployment(LoongLaunchFactory.TokenParams memory p, address pairToken, address launcher)
        internal
        view
        returns (LaunchDeployment memory d)
    {
        (d.phantomQuote, d.graduationThreshold) = pairToken == address(0)
            ? (factory.getLaunchConfig(0).phantomQuote, factory.getLaunchConfig(0).graduationThreshold)
            : _pairEcon(pairToken);
        d.pairToken = pairToken;
        d.creatorFeeRecipient = p.creatorFeeRecipient == address(0) ? launcher : p.creatorFeeRecipient;
        d.originalDeployer = launcher;
        d.feePolicy = ILoongFeePolicy(address(hook));
        d.policy = hook.currentFeePolicy();
        d.feeEscrow = ILoongFeeEscrow(address(escrow));
        d.buybackVault = buyback;
        d.curveFeeBps = factory.getLaunchConfig(0).curveFeeBps;
        d.creatorTaxBps = p.creatorTaxBps;
        d.buybackEnabled = p.buybackEnabled;
        d.supply = factory.getLaunchConfig(0).supply;
        d.name = p.name; d.symbol = p.symbol; d.logo = p.logo; d.description = p.description; d.socials = p.socials;
    }

    function _curveHash(LaunchDeployment memory d) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(LoongBondingCurve).creationCode,
                abi.encode(
                    d.pairToken, d.creatorFeeRecipient, address(factory), d.feePolicy, d.policy, d.feeEscrow,
                    d.buybackVault, d.phantomQuote, d.curveFeeBps, d.creatorTaxBps, d.buybackEnabled,
                    d.graduationThreshold
                )
            )
        );
    }

    /// CREATE2 token address for one salt. Allocation-free: the loop runs ~65k times on average, so every
    /// byte it allocates (abi.encodePacked, type(...).creationCode) would compound into MemoryOOG.
    function _tokenAt(address launcher, bytes32 salt, bytes32 curveHash, bytes memory init, address deployer, uint256 slot)
        internal
        pure
        returns (address tk)
    {
        assembly {
            let buf := mload(0x40) // scratch above the free pointer, never claimed
            mstore(buf, launcher)
            mstore(add(buf, 0x20), salt)
            let s := keccak256(buf, 0x40) // keccak256(abi.encode(launcher, salt))
            mstore8(buf, 0xff)
            mstore(add(buf, 0x01), shl(96, deployer))
            mstore(add(buf, 0x15), s)
            mstore(add(buf, 0x35), curveHash)
            let cv := and(keccak256(buf, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
            mstore(add(add(init, 32), slot), cv)
            let initHash := keccak256(add(init, 32), mload(init))
            mstore8(buf, 0xff)
            mstore(add(buf, 0x01), shl(96, deployer))
            mstore(add(buf, 0x15), s)
            mstore(add(buf, 0x35), initHash)
            tk := and(keccak256(buf, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// Guards the hand-rolled derivation against the deployer's own view before the loop trusts it.
    function _checkDerivation(LaunchDeployment memory d, bytes32 curveHash, bytes memory init, address deployer, uint256 slot)
        internal
        view
    {
        d.salt = bytes32(uint256(7));
        (address tk,) = factory.launchDeployer().predictLaunchAddresses(d);
        require(_tokenAt(d.originalDeployer, d.salt, curveHash, init, deployer, slot) == tk, "derivation drifted from deployer");
    }

    /// Byte length of the token's ABI-encoded constructor args, so the curve slot is found from the end of init.
    function _argsLength(LaunchDeployment memory d) internal view returns (uint256) {
        return abi.encode(d.name, d.symbol, d.logo, d.description, d.socials, d.originalDeployer, address(0), address(factory), d.supply).length;
    }

    /// The platform-token vault's immutable controller; BuybackBurner.t.sol swaps in the burner proxy.
    function _foundationController() internal virtual returns (address) {
        return owner;
    }

    function _pairEcon(address pairToken) internal view returns (uint256 phantom, uint256 threshold) {
        (phantom, threshold,) = factory.pairTokenEconomics(pairToken);
    }

    function _launch(string memory sym, address pairToken) internal returns (address token, LoongBondingCurve curve) {
        LoongLaunchFactory.TokenParams memory p = _params(sym);
        p.salt = _mine(p, pairToken, creator);
        p.expectedEconomics = factory.previewLaunchEconomics(0, pairToken);
        vm.prank(creator);
        address c;
        (token, c) = factory.launchToken(p, 0, pairToken, false);
        curve = LoongBondingCurve(payable(c));
        assertEq(uint16(uint160(token)), 0x9999, "token address must end in 9999");
    }

    /// Launch -> buy -> sell -> complete curve -> seed Infinity pool -> trade on pool -> fees claimable.
    function test_FullLifecycle_BNB() public {
        (address token, LoongBondingCurve curve) = _launch("TST", address(0));
        vm.warp(block.timestamp + 60); // outside the snipe window

        // Alice buys 1 BNB, sells half.
        vm.prank(alice);
        uint256 got = curve.buy{value: 1 ether}(1 ether, 1, alice);
        assertGt(got, 0, "no tokens");
        vm.startPrank(alice);
        IERC20(token).approve(address(curve), got / 2);
        uint256 back = curve.sell(got / 2, 1, alice);
        vm.stopPrank();
        console2.log("alice bought tokens", got / 1e18, "sold half for wei", back);

        // Whale overbuys; the curve clamps and refunds, then sweeps.
        uint256 whaleBefore = whale.balance;
        vm.prank(whale);
        curve.buy{value: 30 ether}(30 ether, 1, whale);
        uint256 spent = whaleBefore - whale.balance;
        console2.log("whale spent (wei) to complete curve", spent);
        assertLt(spent, 30 ether, "no refund");

        assertEq(uint8(factory.getLaunchedToken(token).phase), uint8(GraduationPhase.Swept), "not swept");

        // Permissionless second step.
        factory.createGraduatedPool(token);
        assertEq(uint8(factory.getLaunchedToken(token).phase), uint8(GraduationPhase.PoolCreated), "no pool");

        // Trade on the Infinity pool both ways.
        PoolKey memory key = factory.poolKeyFor(token);
        assertTrue(key.currency0.isNative(), "BNB should be currency0");
        vm.prank(alice);
        uint256 out = swapper.swap{value: 0.5 ether}(key, true, 0.5 ether);
        console2.log("pool buy: 0.5 BNB ->", out / 1e18, "tokens");
        assertGt(out, 0);

        vm.startPrank(alice);
        IERC20(token).approve(address(swapper), out);
        uint256 bnbOut = swapper.swap(key, false, out);
        vm.stopPrank();
        console2.log("pool round trip 0.5 BNB -> wei", bnbOut);
        // Round trip should lose roughly 1% each way plus price impact, never gain.
        assertLt(bnbOut, 0.5 ether);
        assertGt(bnbOut, 0.45 ether);

        // Hook fees swept to escrow by the operator (owner), creator claims.
        PoolId pid = PoolId.wrap(factory.poolIdFor(token)); // outside the prank: a view call would consume it
        vm.prank(owner);
        hook.sweepPoolFees(pid, 1, 1); // a real keeper passes quoted minimums; 1 just proves the path
        uint256 creatorOwed = escrow.balanceOf(creator);
        uint256 protocolOwed = escrow.balanceOf(protocol);
        console2.log("escrow creator wei", creatorOwed, "protocol wei", protocolOwed);
        assertGt(creatorOwed, 0, "creator got nothing");
        uint256 cb = creator.balance;
        vm.prank(creator);
        escrow.claim();
        assertEq(creator.balance - cb, creatorOwed);
        // The ledger must be backed by real BNB, not just numbers.
        assertGe(address(escrow).balance, escrow.balanceOf(protocol), "escrow insolvent");
        // The launch fee (0.002 BNB) is paid straight to the protocol wallet, so compare deltas.
        uint256 pb = protocol.balance;
        vm.prank(protocol);
        escrow.claim();
        assertEq(protocol.balance - pb, protocolOwed, "protocol claim");

        // Liquidity is locked: the locker holds the position NFT.
        (bool ok,) = address(locker).call(abi.encodeWithSignature("withdraw(uint256)", 1));
        assertFalse(ok, "locker should have no withdraw");
    }

    /// 3-second window: 14 halvings over 3s at whole-second resolution -> 98% (capped), 6.2%, 0.19%, then 0.
    /// Times are read from the curve, not cached from block.timestamp: under via-IR a cached timestamp is re-read
    /// after vm.warp, which silently shifts every later warp by the previous one.
    function test_SnipeTax() public {
        (, LoongBondingCurve curve) = _launch("SNP", address(0));
        uint256 t0 = curve.launchedAt();
        assertEq(curve.currentSnipeTaxBps(creator), 0, "creator exempt");
        assertEq(curve.currentSnipeTaxBps(alice), 9900, "raw start");
        vm.warp(t0 + 1);
        assertEq(curve.currentSnipeTaxBps(alice), 618, "second 1: 9900 >> 4");
        vm.warp(t0 + 2);
        assertEq(curve.currentSnipeTaxBps(alice), 19, "second 2: 9900 >> 9");
        vm.warp(t0 + 3);
        assertEq(curve.currentSnipeTaxBps(alice), 0, "window over");
    }

    function _untaxedOut(LoongBondingCurve curve, uint256 quoteIn) internal view returns (uint256) {
        (uint256 q, uint256 tr) = curve.getReserves();
        uint256 net = quoteIn * 99 / 100; // 1% fee only
        return net * tr / (q + net);
    }

    /// What a sniper actually keeps in each second, measured against an untaxed buy at the same moment,
    /// and where the tax goes (70% creator, same split as fees).
    function test_SnipeTax_RealBuys() public {
        (, LoongBondingCurve curve) = _launch("SNP2", address(0));
        uint256 t0 = curve.launchedAt();
        address[4] memory who = [alice, whale, makeAddr("s2"), makeAddr("s3")];
        uint256[4] memory keptPct;
        for (uint256 i = 0; i < 4; ++i) {
            vm.warp(t0 + i);
            vm.deal(who[i], 1 ether);
            uint256 fair = _untaxedOut(curve, 1 ether);
            vm.prank(who[i]);
            uint256 got = curve.buy{value: 1 ether}(1 ether, 1, who[i]);
            keptPct[i] = got * 10000 / fair;
            console2.log("second", i, "kept bps of untaxed:", keptPct[i]);
        }
        // Net spend 1% vs 99% (98% capped snipe + 1% fee); a smaller buy moves the curve less, hence a bit over 1%.
        assertLt(keptPct[0], 150, "second 0: ~1% kept");
        // 0.9282/0.99 scaled by the curve's convexity at this depth: (Q+0.99)/(Q+0.9282) with Q ~ 4.81 BNB -> ~94.8%.
        assertApproxEqAbs(keptPct[1], 9477, 15, "second 1: 6.18% tax");
        assertApproxEqAbs(keptPct[2], 9981, 5, "second 2: ~0.19% tax");
        assertEq(keptPct[3], 10000, "second 3: no tax");

        vm.prank(owner);
        curve.sweepFees(1);
        console2.log("creator earned from snipes+fees (wei)", escrow.balanceOf(creator));
        // second-0 alone: 98% snipe + 1% fee = 0.99 BNB into the split, 70% to the creator
        assertGt(escrow.balanceOf(creator), 0.693 ether);
    }

    /// Same lifecycle with USDT as the quote asset.
    function test_FullLifecycle_USDT() public {
        deal(USDT, alice, 50_000 ether);
        deal(USDT, whale, 50_000 ether);
        (address token, LoongBondingCurve curve) = _launch("USD", USDT);
        vm.warp(block.timestamp + 60);

        vm.startPrank(alice);
        IERC20(USDT).approve(address(curve), 1000 ether);
        uint256 got = curve.buy(1000 ether, 1, alice);
        vm.stopPrank();
        assertGt(got, 0);

        vm.startPrank(whale);
        IERC20(USDT).approve(address(curve), 20_000 ether);
        curve.buy(20_000 ether, 1, whale);
        vm.stopPrank();
        assertEq(uint8(factory.getLaunchedToken(token).phase), uint8(GraduationPhase.Swept));

        factory.createGraduatedPool(token);
        PoolKey memory key = factory.poolKeyFor(token);
        bool usdtIs0 = Currency.unwrap(key.currency0) == USDT;

        vm.startPrank(alice);
        IERC20(USDT).approve(address(swapper), 100 ether);
        uint256 out = swapper.swap(key, usdtIs0, 100 ether);
        IERC20(token).approve(address(swapper), out);
        uint256 usdtBack = swapper.swap(key, !usdtIs0, out);
        vm.stopPrank();
        console2.log("USDT pool round trip 100 ->", usdtBack / 1e16, "cents");
        assertLt(usdtBack, 100 ether);
        assertGt(usdtBack, 90 ether);
    }

    // ---------------------------------------------------------------------
    // LaunchAndBuy router
    // ---------------------------------------------------------------------

    /// Opening buy in the launch tx: recorded under the real caller, recipient not snipe-taxed.
    function test_Router_LaunchAndBuy_Native() public {
        LoongLaunchFactory.TokenParams memory p = _params("RTR");
        p.salt = _mine(p, address(0), creator);
        p.expectedEconomics = factory.previewLaunchEconomics(0, address(0));
        address bag = makeAddr("bag");
        vm.prank(creator);
        (address token, address curve, uint256 out) =
            router.launchAndBuy{value: 1 ether}(p, 0, address(0), 1 ether, 1, bag, false);

        assertEq(factory.getLaunchedToken(token).deployer, creator, "launch not attributed to caller");
        assertEq(IERC20(token).balanceOf(bag), out);
        // Untaxed: 1 BNB less 1% fee against the 4.8 BNB phantom -> 0.99/5.79 of the curve's 1e9 supply.
        uint256 expected = uint256(1_000_000_000 ether) * 0.99 ether / 5.79 ether;
        assertApproxEqRel(out, expected, 0.001e18, "opening buy was snipe-taxed");
        assertEq(address(router).balance, 0, "router kept BNB");
        assertEq(LoongBondingCurve(payable(curve)).currentSnipeTaxBps(bag), 0);
    }

    /// Overbuying in the launch tx graduates immediately and refunds the unspent BNB to the caller.
    function test_Router_OverbuyRefunds() public {
        LoongLaunchFactory.TokenParams memory p = _params("BIG");
        p.salt = _mine(p, address(0), creator);
        p.expectedEconomics = factory.previewLaunchEconomics(0, address(0));
        uint256 before = creator.balance;
        vm.prank(creator);
        (address token,,) = router.launchAndBuy{value: 40 ether}(p, 0, address(0), 40 ether, 1, creator, false);
        uint256 paid = before - creator.balance;
        console2.log("paid to buy out whole curve (wei)", paid);
        assertLt(paid, 20 ether, "refund missing");
        assertEq(address(router).balance, 0, "router kept BNB");
        assertEq(uint8(factory.getLaunchedToken(token).phase), uint8(GraduationPhase.Swept));
    }

    function test_Router_USDT() public {
        deal(USDT, creator, 5000 ether);
        LoongLaunchFactory.TokenParams memory p = _params("RUS");
        p.salt = _mine(p, USDT, creator);
        p.expectedEconomics = factory.previewLaunchEconomics(0, USDT);
        vm.startPrank(creator);
        IERC20(USDT).approve(address(router), 500 ether);
        (address token,, uint256 out) = router.launchAndBuy(p, 0, USDT, 500 ether, 1, creator, false);
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(creator), out);
        assertEq(IERC20(USDT).balanceOf(creator), 4500 ether);
        assertEq(IERC20(USDT).balanceOf(address(router)), 0);
    }

    function test_Router_RejectsZeroMinimumAndWrongValue() public {
        LoongLaunchFactory.TokenParams memory p = _params("ERR");
        p.expectedEconomics = factory.previewLaunchEconomics(0, address(0));
        vm.prank(creator);
        vm.expectRevert(LaunchAndBuy.MinimumOutputRequired.selector);
        router.launchAndBuy{value: 1 ether}(p, 0, address(0), 1 ether, 0, creator, false);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LaunchAndBuy.NativeValueMismatch.selector, 1.5 ether, 1 ether));
        router.launchAndBuy{value: 1.5 ether}(p, 0, address(0), 1 ether, 1, creator, false);
    }

    /// Only the router may claim to launch on someone else's behalf.
    function test_OnlyForwarderCanLaunchFor() public {
        LoongLaunchFactory.TokenParams memory p = _params("FWD");
        vm.prank(alice);
        vm.expectRevert(LoongLaunchFactory.NotLaunchForwarder.selector);
        factory.launchTokenFor(p, 0, address(0), creator);
    }

    // ---------------------------------------------------------------------
    // SwapAndBuy: BNB -> quote asset -> curve, one tx
    // ---------------------------------------------------------------------

    address constant UR = 0xd9C500DfF816a1Da21A48A732d3498Bf09dc9AEB;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function _bnbToUsdtProgram(uint256 amountIn, uint24 fee)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        commands = hex"0b00"; // WRAP_ETH, V3_SWAP_EXACT_IN
        inputs = new bytes[](2);
        inputs[0] = abi.encode(address(2), amountIn); // wrap into the router itself
        inputs[1] = abi.encode(address(1), amountIn, uint256(0), abi.encodePacked(WBNB, fee, USDT), false); // to caller
    }

    function test_SwapAndBuy_BNBIntoUSDTCurve() public {
        SwapAndBuy sab = new SwapAndBuy(factory, IUniversalRouter(UR), owner);
        (address token,) = _launch("SAB", USDT);
        vm.warp(block.timestamp + 60);

        (bytes memory commands, bytes[] memory inputs) = _bnbToUsdtProgram(1 ether, 100);
        vm.prank(alice);
        uint256 out = sab.swapAndBuy{value: 1 ether}(token, commands, inputs, block.timestamp + 60, 100 ether, 1, alice);
        console2.log("1 BNB -> tokens", out / 1e18);
        assertEq(IERC20(token).balanceOf(alice), out);
        assertEq(IERC20(USDT).balanceOf(address(sab)), 0, "kept USDT");
        assertEq(address(sab).balance, 0, "kept BNB");
    }

    function test_SwapAndBuy_RejectsNativeCurveAndShortSwap() public {
        SwapAndBuy sab = new SwapAndBuy(factory, IUniversalRouter(UR), owner);
        (address bnbToken,) = _launch("NAT", address(0));
        (bytes memory commands, bytes[] memory inputs) = _bnbToUsdtProgram(1 ether, 100);
        vm.prank(alice);
        vm.expectRevert(SwapAndBuy.NativeQuote.selector);
        sab.swapAndBuy{value: 1 ether}(bnbToken, commands, inputs, block.timestamp + 60, 1, 1, alice);

        (address usdToken,) = _launch("SHT", USDT);
        vm.prank(alice);
        vm.expectPartialRevert(SwapAndBuy.InsufficientQuoteOut.selector); // 1 BNB cannot deliver 100k USDT
        sab.swapAndBuy{value: 1 ether}(usdToken, commands, inputs, block.timestamp + 60, 100_000 ether, 1, alice);
    }

    // ---------------------------------------------------------------------
    // swapLaunchAndBuy: launch a pair-token coin and pay the opening buy in BNB, one tx
    // ---------------------------------------------------------------------

    address constant BNCB = 0x4902C5ebc598265Ed2212b559B042De8a5Eeec3f;

    /// BNB -> `quoteToken` in one V3 hop, delivered to the caller (the router), leftover BNB swept back to it.
    function _bnbToProgram(uint256 amountIn, uint24 fee, address quoteToken)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        commands = hex"0b0004"; // WRAP_ETH, V3_SWAP_EXACT_IN, SWEEP
        inputs = new bytes[](3);
        inputs[0] = abi.encode(address(2), amountIn);
        inputs[1] = abi.encode(address(1), amountIn, uint256(0), abi.encodePacked(WBNB, fee, quoteToken), false);
        inputs[2] = abi.encode(address(0), address(1), uint256(0));
    }

    function test_SwapLaunch_USDT_WithExemptions() public {
        LoongLaunchFactory.TokenParams memory p = _params("SWL");
        p.salt = _mine(p, USDT, creator);
        p.expectedEconomics = factory.previewLaunchEconomics(0, USDT);
        (bytes memory commands, bytes[] memory inputs) = _bnbToProgram(1 ether, 100, USDT);
        address friend = address(uint160(uint256(keccak256("loong.swaplaunch.friend"))));
        address[] memory ex = new address[](1);
        ex[0] = friend;
        vm.deal(creator, 2 ether);
        uint256 usdtBefore = IERC20(USDT).balanceOf(creator);
        vm.prank(creator);
        (address token, address curve, uint256 out) = router.swapLaunchAndBuy{value: 1 ether}(
            p, 0, USDT, commands, inputs, block.timestamp + 60, 100 ether, 1, creator, false, ex
        );
        console2.log("1 BNB opening buy -> tokens", out / 1e18);
        assertTrue(out > 0);
        assertEq(IERC20(token).balanceOf(creator), out, "creator holds the opening buy");
        assertEq(creator.balance, 1 ether, "exactly 1 BNB spent");
        assertEq(IERC20(USDT).balanceOf(creator), usdtBefore, "creator never needed USDT");
        assertEq(IERC20(USDT).balanceOf(address(router)), 0, "router kept USDT");
        assertEq(address(router).balance, 0, "router kept BNB");
        assertEq(factory.getLaunchedToken(token).deployer, creator, "launcher is the creator, not the router");
        assertTrue(LoongBondingCurve(payable(curve)).snipeTaxExempt(friend), "exemption list applied");
        assertTrue(LoongBondingCurve(payable(curve)).snipeTaxExempt(creator), "recipient exempt");
        assertEq(uint256(uint16(uint160(token))), 0x9999, "vanity address");
    }

    function test_SwapLaunch_RealStockToken_BNCB() public {
        vm.prank(owner);
        factory.setPairTokenEconomics(BNCB, 650 ether, 1650 ether, 18); // ~$4k / $10k at ~$6 per BNCB
        vm.prank(owner);
        factory.setPairTokenApproved(BNCB, true);
        LoongLaunchFactory.TokenParams memory p = _params("STK");
        p.salt = _mine(p, BNCB, creator);
        p.expectedEconomics = factory.previewLaunchEconomics(0, BNCB);
        (bytes memory commands, bytes[] memory inputs) = _bnbToProgram(0.5 ether, 100, BNCB);
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        (address token,, uint256 out) = router.swapLaunchAndBuy{value: 0.5 ether}(
            p, 0, BNCB, commands, inputs, block.timestamp + 60, 1 ether, 1, creator, false, new address[](0)
        );
        console2.log("0.5 BNB -> BNCB -> tokens", out / 1e18);
        assertEq(IERC20(token).balanceOf(creator), out);
        assertEq(IERC20(BNCB).balanceOf(creator), 0, "creator never held BNCB");
        assertEq(IERC20(BNCB).balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
    }

    /// An opening buy bigger than the curve: the curve clamps, the unspent pair token goes back to the creator.
    function test_SwapLaunch_OverbuyRefundsPairToken() public {
        LoongLaunchFactory.TokenParams memory p = _params("OVB");
        p.salt = _mine(p, USDT, creator);
        p.expectedEconomics = factory.previewLaunchEconomics(0, USDT);
        (bytes memory commands, bytes[] memory inputs) = _bnbToProgram(20 ether, 100, USDT); // ~15k USDT > 10k threshold
        vm.deal(creator, 20 ether);
        uint256 usdtBefore = IERC20(USDT).balanceOf(creator);
        vm.prank(creator);
        (address token,,) = router.swapLaunchAndBuy{value: 20 ether, gas: 8_000_000}(
            p, 0, USDT, commands, inputs, block.timestamp + 60, 1000 ether, 1, creator, false, new address[](0)
        );
        uint256 refunded = IERC20(USDT).balanceOf(creator) - usdtBefore;
        console2.log("refunded USDT", refunded / 1e18);
        assertGt(refunded, 1000 ether, "unspent USDT refunded");
        assertEq(IERC20(USDT).balanceOf(address(router)), 0);
        assertTrue(uint256(factory.getLaunchedToken(token).phase) >= 1, "graduated in the launch tx");
    }

    /// An exempt wallet that only holds BNB buys through SwapAndBuy in the launch second and pays no snipe tax:
    /// the curve keys the exemption on the recipient, so routing through a contract does not lose it.
    function test_ExemptWallet_BNBRoutedBuy_NoSnipeTax() public {
        address friend = address(uint160(uint256(keccak256("loong.exempt.friend"))));
        address stranger = address(uint160(uint256(keccak256("loong.exempt.stranger"))));
        SwapAndBuy sab = new SwapAndBuy(factory, IUniversalRouter(UR), owner);
        LoongLaunchFactory.TokenParams memory p = _params("EXF");
        p.salt = _mine(p, USDT, creator);
        p.expectedEconomics = factory.previewLaunchEconomics(0, USDT);
        address[] memory ex = new address[](1);
        ex[0] = friend;
        (bytes memory c0, bytes[] memory i0) = _bnbToProgram(0.2 ether, 100, USDT);
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        (address token, address curve,) = router.swapLaunchAndBuy{value: 0.2 ether}(
            p, 0, USDT, c0, i0, block.timestamp + 60, 1, 1, creator, false, ex
        );
        // Same second as the launch: the 98% window.
        assertEq(LoongBondingCurve(payable(curve)).currentSnipeTaxBps(friend), 0);
        assertGt(LoongBondingCurve(payable(curve)).currentSnipeTaxBps(stranger), 9000);
        (bytes memory c1, bytes[] memory i1) = _bnbToProgram(0.2 ether, 100, USDT);
        vm.deal(friend, 1 ether);
        vm.prank(friend);
        uint256 outFriend = sab.swapAndBuy{value: 0.2 ether}(token, c1, i1, block.timestamp + 60, 1, 1, friend);
        (bytes memory c2, bytes[] memory i2) = _bnbToProgram(0.2 ether, 100, USDT);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        uint256 outStranger = sab.swapAndBuy{value: 0.2 ether}(token, c2, i2, block.timestamp + 60, 1, 1, stranger);
        console2.log("same 0.2 BNB in the launch second: exempt", outFriend / 1e18, "stranger", outStranger / 1e18);
        assertGt(outFriend, outStranger * 20, "stranger paid the snipe tax, the exempt wallet did not");
    }

    /// Sell program: the router already holds the pair token; swap all of it to WBNB here, unwrap to the caller.
    function _sellToBnbProgram(address quoteToken, uint24 fee, uint256 minBnb)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        commands = hex"000c"; // V3_SWAP_EXACT_IN, UNWRAP_WETH
        inputs = new bytes[](2);
        inputs[0] = abi.encode(address(2), uint256(1) << 255, uint256(0), abi.encodePacked(quoteToken, fee, WBNB), false);
        inputs[1] = abi.encode(address(1), minBnb);
    }

    function test_SellAndSwap_USDTCoinToBNB() public {
        // A keyless seller: public test addresses like `seller` carry EIP-7702 sweepers on BSC that forward any
        // BNB they receive, which would hide the payout this test is about.
        address seller = address(uint160(uint256(keccak256("loong.sellandswap.seller"))));
        SwapAndBuy sab = new SwapAndBuy(factory, IUniversalRouter(UR), owner);
        (address token,) = _launch("SEL", USDT);
        vm.warp(block.timestamp + 60);
        (bytes memory cb, bytes[] memory ib) = _bnbToUsdtProgram(1 ether, 100);
        vm.deal(seller, 2 ether);
        vm.prank(seller);
        uint256 bought = sab.swapAndBuy{value: 1 ether}(token, cb, ib, block.timestamp + 60, 1, 1, seller);

        uint256 bnbBefore = seller.balance;
        uint256 usdtBefore = IERC20(USDT).balanceOf(seller);
        (bytes memory cs, bytes[] memory is_) = _sellToBnbProgram(USDT, 100, 0);
        vm.startPrank(seller);
        IERC20(token).approve(address(sab), bought);
        uint256 bnbOut = sab.sellAndSwap(token, bought, 1, cs, is_, block.timestamp + 60, 0.9 ether, seller);
        vm.stopPrank();
        console2.log("1 BNB in, all sold back -> BNB out (milli)", bnbOut / 1e15);
        assertEq(IERC20(token).balanceOf(seller), 0, "all coins sold");
        assertEq(seller.balance - bnbBefore, bnbOut, "BNB paid to the seller");
        assertEq(IERC20(USDT).balanceOf(seller), usdtBefore, "seller never touched USDT");
        assertGt(bnbOut, 0.95 ether, "round trip loses only fees");
        assertEq(IERC20(USDT).balanceOf(address(sab)), 0, "contract kept USDT");
        assertEq(IERC20(token).balanceOf(address(sab)), 0, "contract kept coins");
        assertEq(address(sab).balance, 0, "contract kept BNB");
    }

    function test_SellAndSwap_Guards() public {
        SwapAndBuy sab = new SwapAndBuy(factory, IUniversalRouter(UR), owner);
        (address bnbToken,) = _launch("SNB", address(0));
        (bytes memory cs, bytes[] memory is_) = _sellToBnbProgram(USDT, 100, 0);
        vm.prank(alice);
        vm.expectRevert(SwapAndBuy.NativeQuote.selector);
        sab.sellAndSwap(bnbToken, 1 ether, 1, cs, is_, block.timestamp + 60, 0, alice);

        (address token,) = _launch("SMN", USDT);
        vm.warp(block.timestamp + 60);
        (bytes memory cb, bytes[] memory ib) = _bnbToUsdtProgram(1 ether, 100);
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        uint256 bought = sab.swapAndBuy{value: 1 ether}(token, cb, ib, block.timestamp + 60, 1, 1, alice);
        vm.startPrank(alice);
        IERC20(token).approve(address(sab), bought);
        vm.expectPartialRevert(SwapAndBuy.InsufficientNativeOut.selector); // demanding 2 BNB back for 1 BNB in
        sab.sellAndSwap(token, bought, 1, cs, is_, block.timestamp + 60, 2 ether, alice);
        vm.stopPrank();
    }

    function test_SwapLaunch_Guards() public {
        LoongLaunchFactory.TokenParams memory p = _params("GRD");
        p.expectedEconomics = factory.previewLaunchEconomics(0, USDT);
        (bytes memory commands, bytes[] memory inputs) = _bnbToProgram(1 ether, 100, USDT);
        vm.deal(creator, 5 ether);
        vm.startPrank(creator);
        vm.expectRevert(LaunchAndBuy.NativeQuote.selector);
        router.swapLaunchAndBuy{value: 1 ether}(p, 0, address(0), commands, inputs, block.timestamp + 60, 1, 1, creator, false, new address[](0));
        vm.expectRevert(LaunchAndBuy.MinimumOutputRequired.selector);
        router.swapLaunchAndBuy{value: 1 ether}(p, 0, USDT, commands, inputs, block.timestamp + 60, 1, 0, creator, false, new address[](0));
        vm.expectPartialRevert(LaunchAndBuy.InsufficientQuoteOut.selector); // 1 BNB cannot deliver 100k USDT
        router.swapLaunchAndBuy{value: 1 ether}(p, 0, USDT, commands, inputs, block.timestamp + 60, 100_000 ether, 1, creator, false, new address[](0));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Loong economics: 1% fee = 0.70 creator / 0.10 platform / 0.10 burn / 0.10 platform-token buyback, no launch fee
    // ---------------------------------------------------------------------

    function test_NoLaunchFee() public {
        LoongLaunchFactory.TokenParams memory p = _params("FREE");
        p.salt = _mine(p, address(0), creator);
        p.expectedEconomics = factory.previewLaunchEconomics(0, address(0));
        vm.prank(creator);
        vm.expectRevert(LoongLaunchFactory.LaunchFeeNotPaid.selector);
        factory.launchToken{value: 0.002 ether}(p, 0, address(0), false);

        uint256 before = creator.balance;
        vm.prank(creator);
        factory.launchToken(p, 0, address(0), false);
        assertEq(creator.balance, before, "launch should cost nothing");
    }

    /// One 10 BNB buy -> 0.1 BNB fee, split to the wei: 0.07 creator, 0.01 platform, 0.01 platform-token vault,
    /// 0.01 buys and burns the coin. Launched with toFoundation=false on purpose: the creator cannot opt out.
    function test_FeeSplit_Exact() public {
        (address token, LoongBondingCurve curve) = _launch("SPLIT", address(0));
        vm.warp(block.timestamp + 60);
        vm.prank(alice);
        curve.buy{value: 10 ether}(10 ether, 1, alice);

        uint256 supplyBefore = IERC20(token).totalSupply();
        vm.prank(owner); // fee sweep operator
        curve.sweepFees(1);

        assertEq(escrow.balanceOf(creator), 0.07 ether, "creator 0.70%");
        assertEq(escrow.balanceOf(protocol), 0.01 ether, "platform 0.10%");
        assertEq(address(foundation).balance, 0.01 ether, "platform-token buyback vault 0.10%");
        uint256 burned = supplyBefore - IERC20(token).totalSupply();
        assertGt(burned, 0, "buyback did not burn");
        console2.log("0.01 BNB buyback burned tokens:", burned / 1e18);
    }

    /// Same split after graduation, on the Infinity hook.
    function test_FeeSplit_AfterGraduation() public {
        (address token, LoongBondingCurve curve) = _launch("POOLSPLIT", address(0));
        vm.warp(block.timestamp + 60);
        vm.prank(whale);
        curve.buy{value: 30 ether}(30 ether, 1, whale);
        factory.createGraduatedPool(token);
        PoolId pid = PoolId.wrap(factory.poolIdFor(token));

        // Sweep whatever the curve/graduation left, so the next numbers are pool fees only.
        vm.prank(owner);
        hook.sweepPoolFees(pid, 1, 1);
        uint256 c0 = escrow.balanceOf(creator);
        uint256 p0 = escrow.balanceOf(protocol);

        PoolKey memory key = factory.poolKeyFor(token);
        vm.prank(alice);
        swapper.swap{value: 10 ether}(key, true, 10 ether); // BNB in: fee taken on the token leg

        uint256 supplyBefore = IERC20(token).totalSupply();
        vm.prank(owner);
        hook.sweepPoolFees(pid, 1, 1);
        uint256 dc = escrow.balanceOf(creator) - c0;
        uint256 dp = escrow.balanceOf(protocol) - p0;
        console2.log("pool fees -> creator wei", dc, "platform wei", dp);
        // Fee was collected in the memecoin and converted to BNB by the sweep, so exact wei values move with the
        // pool price; the ratio between the legs is what the policy fixes.
        assertApproxEqRel(dc * 10, dp * 70, 0.001e18, "creator:platform must be 70:10");
        assertGt(address(foundation).balance, 0, "pool fees must feed the platform-token vault too");
        assertLt(IERC20(token).totalSupply(), supplyBefore, "pool buyback did not burn");
    }

    /// A salt that does not land on ...9999 is refused, so every Loong coin carries the suffix.
    function test_VanitySuffixEnforced() public {
        LoongLaunchFactory.TokenParams memory p = _params("NOPE");
        p.expectedEconomics = factory.previewLaunchEconomics(0, address(0));
        p.salt = bytes32(uint256(_mine(p, address(0), creator)) + 1); // the next salt almost surely misses
        vm.prank(creator);
        vm.expectPartialRevert(LoongLaunchFactory.VanitySuffixRequired.selector);
        factory.launchToken(p, 0, address(0), false);

        p.salt = _mine(p, address(0), creator);
        vm.prank(creator);
        (address token,) = factory.launchToken(p, 0, address(0), false);
        console2.log("mined token address", token);
        assertEq(uint16(uint160(token)), 0x9999);
    }

    /// Genius's legacy router ABI (no destination flag) works unchanged, so integrations written for Genius can launch on Loong.
    function test_Router_LegacyOverloads() public {
        LoongLaunchFactory.TokenParams memory p = _params("LEG1");
        p.salt = _mine(p, address(0), creator);
        p.expectedEconomics = factory.previewLaunchEconomics(0, address(0));
        vm.prank(creator);
        (address token,,) = router.launchAndBuy{value: 1 ether}(p, 0, address(0), 1 ether, 1, creator);
        assertGt(IERC20(token).balanceOf(creator), 0, "legacy 6-arg launch bought nothing");
        assertEq(uint16(uint160(token)), 0x9999);

        address friend = makeAddr("friend");
        LoongLaunchFactory.TokenParams memory p2 = _params("LEG2");
        p2.salt = _mine(p2, address(0), creator);
        p2.expectedEconomics = factory.previewLaunchEconomics(0, address(0));
        address[] memory ex = new address[](1);
        ex[0] = friend;
        uint256 before = creator.balance;
        vm.prank(creator);
        (address token2, address curve2,) = router.launchAndBuy{value: 20 ether}(p2, 0, address(0), 20 ether, 1, creator, ex);
        assertLt(before - creator.balance, 13 ether, "overbuy not refunded");
        assertEq(LoongBondingCurve(payable(curve2)).currentSnipeTaxBps(friend), 0, "declared wallet not exempt");
        assertGt(LoongBondingCurve(payable(curve2)).currentSnipeTaxBps(alice), 0, "stranger should be taxed");
        assertEq(uint16(uint160(token2)), 0x9999);
        assertEq(address(router).balance, 0, "router kept BNB");
    }

    /// Rescue returns funds sent to a router by mistake, only to the owner's instruction, and cannot reach
    /// anything users merely approved.
    function test_Router_Rescue() public {
        deal(USDT, alice, 1000 ether);
        // alice approves the router generously (as wallets often do) but never uses it
        vm.prank(alice);
        IERC20(USDT).approve(address(router), type(uint256).max);
        // bob fat-fingers 50 USDT and 1 BNB straight to the router.
        // Not makeAddr("bob"): its key is keccak("bob"), public, and on the BSC fork that address carries an
        // EIP-7702 sweeper that forwards any BNB it receives. Use an address nobody holds a key for.
        address bob = address(uint160(uint256(keccak256("loong.rescue.test.bob"))));
        deal(USDT, bob, 50 ether);
        vm.deal(bob, 1 ether);
        vm.startPrank(bob);
        IERC20(USDT).transfer(address(router), 50 ether);
        (bool ok,) = address(router).call{value: 1 ether}("");
        vm.stopPrank();
        assertTrue(ok);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        router.rescue(USDT, alice);

        vm.startPrank(owner);
        router.rescue(USDT, bob);
        router.rescue(address(0), bob);
        vm.stopPrank();
        assertEq(IERC20(USDT).balanceOf(bob), 50 ether, "bob's USDT back");
        assertEq(bob.balance, 1 ether, "bob's BNB back");
        assertEq(IERC20(USDT).balanceOf(alice), 1000 ether, "rescue must not touch approved-but-unspent funds");

        // Nothing left to take: a second rescue moves zero.
        vm.prank(owner);
        router.rescue(USDT, owner);
        assertEq(IERC20(USDT).balanceOf(owner), 0);
    }

    function test_SwapAndBuy_Rescue() public {
        SwapAndBuy sab = new SwapAndBuy(factory, IUniversalRouter(UR), owner);
        deal(USDT, address(sab), 7 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        sab.rescue(USDT, alice);
        vm.prank(owner);
        sab.rescue(USDT, alice);
        assertEq(IERC20(USDT).balanceOf(alice), 7 ether);
    }
}
