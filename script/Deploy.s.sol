// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {LoongLaunchFactory} from "../src/LoongLaunchFactory.sol";
import {LoongLaunchLocker} from "../src/LoongLaunchLocker.sol";
import {LoongBuybackVault} from "../src/LoongBuybackVault.sol";
import {LoongLaunchDeployer} from "../src/LoongLaunchDeployer.sol";
import {LoongGraduationExecutor} from "../src/LoongGraduationExecutor.sol";
import {LoongFoundationVault} from "../src/LoongFoundationVault.sol";
import {LoongMemeHook} from "../src/hooks/LoongMemeHook.sol";
import {ILoongMemeHook} from "../src/interfaces/ILoongMemeHook.sol";
import {ILoongFeeEscrow} from "../src/interfaces/ILaunchpadV2.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {LaunchAndBuy} from "../src/LaunchAndBuy.sol";
import {SwapAndBuy, IUniversalRouter} from "../src/SwapAndBuy.sol";
import {MockUSDT} from "./MockUSDT.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LoongBuybackBurner, IFoundationVault, IUniversalRouterLike} from "../src/LoongBuybackBurner.sol";

/**
 * Deploys and wires the whole Loong stack from one config file:
 *
 *   CONFIG=../config/economics.testnet.json forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --slow
 *
 * `--slow` waits for each receipt before sending the next transaction. Without it a dropped or
 * re-ordered nonce leaves later wiring calls pointing at contracts that were never created.
 *
 * Every economic number comes from the config; nothing is hard-coded here. On mainnet the script
 * refuses to run unless owner, fee recipient and vault controller are real addresses that are not
 * the deployer, because the fee recipient is snapshotted into every launch and the vault controller
 * is immutable: getting either wrong cannot be fixed after the first coin launches.
 */
contract Deploy is Script {
    struct Out {
        address escrow;
        address hook;
        address locker;
        address buyback;
        address factory;
        address deployer_;
        address executor;
        address foundationVault;
        address launchAndBuy;
        address swapAndBuy;
        address mockUsdt;
        address buybackBurner;
    }

    string json;
    address deployer;

    function _addr(string memory key) internal view returns (address) {
        string memory v = vm.parseJsonString(json, key);
        if (keccak256(bytes(v)) == keccak256("deployer")) return deployer;
        return vm.parseAddress(v);
    }

    function _u(string memory key) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, key));
    }

    function _config(string memory prefix) internal view returns (LoongLaunchFactory.LaunchConfig memory c) {
        c.supply = _u(string.concat(prefix, ".supply"));
        c.curveFeeBps = vm.parseJsonUint(json, string.concat(prefix, ".curveFeeBps"));
        c.phantomQuote = _u(string.concat(prefix, ".phantomQuote"));
        c.graduationThreshold = _u(string.concat(prefix, ".graduationThreshold"));
        c.poolFee = uint24(vm.parseJsonUint(json, string.concat(prefix, ".poolFee")));
        c.tickSpacing = int24(int256(vm.parseJsonUint(json, string.concat(prefix, ".tickSpacing"))));
        c.enabled = vm.parseJsonBool(json, string.concat(prefix, ".enabled"));
    }

    function run() external returns (Out memory o) {
        json = vm.readFile(vm.envString("CONFIG"));
        uint256 pk = vm.envUint("DEPLOYER_PK");
        deployer = vm.addr(pk);
        require(block.chainid == vm.parseJsonUint(json, ".chainId"), "config is for a different chain");

        address owner = _addr(".owner");
        address feeRecipient = _addr(".protocolFeeRecipient");
        // "burner": the platform-token vault is controlled by a LoongBuybackBurner proxy deployed here (Steven
        // 2026-09-24: 100% of that share buys $LOONG and burns it, automatically). Otherwise a plain address.
        bool useBurner = keccak256(bytes(vm.parseJsonString(json, ".foundationVaultController"))) == keccak256("burner");
        address vaultController = useBurner ? address(0) : _addr(".foundationVaultController");
        if (block.chainid == 56) {
            require(owner != deployer && feeRecipient != deployer && (useBurner || vaultController != deployer), "mainnet: set real addresses");
            require(owner.code.length != 0, "mainnet: owner must be the Safe");
        }

        ICLPoolManager pm = ICLPoolManager(vm.parseJsonAddress(json, ".infinity.clPoolManager"));
        ICLPositionManager posm = ICLPositionManager(vm.parseJsonAddress(json, ".infinity.clPositionManager"));
        IAllowanceTransfer permit2 = IAllowanceTransfer(vm.parseJsonAddress(json, ".infinity.permit2"));

        vm.startBroadcast(pk);

        FeeEscrow escrow = new FeeEscrow();
        LoongMemeHook hook = new LoongMemeHook(
            pm,
            ILoongFeeEscrow(address(escrow)),
            feeRecipient,
            uint16(vm.parseJsonUint(json, ".hookLegacy.protocolFeeShareBps")),
            uint16(vm.parseJsonUint(json, ".launchConfig0.curveFeeBps")),
            deployer
        );
        LoongLaunchLocker locker = new LoongLaunchLocker(deployer, address(posm));
        LoongBuybackVault buyback = new LoongBuybackVault(deployer, hook, ILoongFeeEscrow(address(escrow)));
        LoongLaunchFactory factory = new LoongLaunchFactory(
            deployer, pm, posm, permit2, locker, ILoongMemeHook(address(hook)), ILoongFeeEscrow(address(escrow)), buyback,
            _u(".launchFeeWei")
        );

        hook.setFactory(address(factory));
        locker.setFactory(address(factory));
        buyback.setFactory(address(factory));
        hook.setBuybackVault(buyback);
        hook.setBuybackBurnBps(vm.parseJsonUint(json, ".hookLegacy.buybackBurnBps"));
        hook.setMaxInternalPriceImpactBps(vm.parseJsonUint(json, ".maxInternalPriceImpactBps"));

        LoongLaunchDeployer launchDeployer = new LoongLaunchDeployer(address(factory));
        factory.setLaunchDeployer(launchDeployer);
        LoongGraduationExecutor executor = new LoongGraduationExecutor(posm, permit2, locker, address(factory));
        factory.setGraduationExecutor(executor);

        factory.addLaunchConfig(_config(".launchConfig0"));
        if (vm.keyExistsJson(json, ".testLaunchConfig")) {
            require(block.chainid != 56, "testLaunchConfig must never reach mainnet");
            factory.addLaunchConfig(_config(".testLaunchConfig"));
        }
        factory.setMaxCreatorTaxBps(vm.parseJsonUint(json, ".maxCreatorTaxBps"));
        factory.setSnipeTaxStartBps(vm.parseJsonUint(json, ".snipeTax.startBps"));
        factory.setSnipeTaxSeconds(vm.parseJsonUint(json, ".snipeTax.seconds"));

        // Fee split. The vault's constructor forwards 1 wei to the controller to prove it can receive BNB.
        LoongBuybackBurner burner;
        if (useBurner) {
            burner = _deployBurner(factory);
            vaultController = address(burner);
        }
        LoongFoundationVault foundation = new LoongFoundationVault{value: 1}(vaultController);
        if (useBurner) burner.setVault(IFoundationVault(address(foundation)));
        hook.setFoundationVault(address(foundation));
        hook.setFoundationFeePolicy(
            uint16(vm.parseJsonUint(json, ".feePolicy.destinationBps")),
            uint16(vm.parseJsonUint(json, ".feePolicy.platformBps")),
            uint16(vm.parseJsonUint(json, ".feePolicy.creatorBps")),
            uint16(vm.parseJsonUint(json, ".feePolicy.buybackBps"))
        );

        // ERC-20 pairs.
        if (vm.keyExistsJson(json, ".mockUsdt")) {
            require(block.chainid != 56, "mock token must never reach mainnet");
            MockUSDT usdt = new MockUSDT();
            factory.setPairTokenEconomics(address(usdt), _u(".mockUsdt.phantomQuote"), _u(".mockUsdt.graduationThreshold"), 18);
            factory.setPairTokenApproved(address(usdt), true);
            o.mockUsdt = address(usdt);
        }
        if (vm.keyExistsJson(json, ".pairTokens")) {
            for (uint256 i = 0; vm.keyExistsJson(json, string.concat(".pairTokens[", vm.toString(i), "]")); ++i) {
                string memory p = string.concat(".pairTokens[", vm.toString(i), "]");
                address t = vm.parseJsonAddress(json, string.concat(p, ".pairToken"));
                factory.setPairTokenEconomics(
                    t, _u(string.concat(p, ".phantomQuote")), _u(string.concat(p, ".graduationThreshold")),
                    uint8(vm.parseJsonUint(json, string.concat(p, ".decimals")))
                );
                factory.setPairTokenApproved(t, true);
            }
        }

        // Routers are owned by the final owner from birth: their only owner power is rescuing stray funds.
        LaunchAndBuy router =
            new LaunchAndBuy(factory, IUniversalRouter(vm.parseJsonAddress(json, ".infinity.universalRouter")), owner);
        factory.setLaunchForwarder(address(router));
        SwapAndBuy swapAndBuy =
            new SwapAndBuy(factory, IUniversalRouter(vm.parseJsonAddress(json, ".infinity.universalRouter")), owner);

        factory.setLaunchEnabled(true);

        // Hand over. Ownable2Step: the Safe must call acceptOwnership() on each of these four afterwards.
        if (owner != deployer) {
            factory.transferOwnership(owner);
            hook.transferOwnership(owner);
            locker.transferOwnership(owner);
            buyback.transferOwnership(owner);
            // Also two-step. The deployer keeps it until the Safe accepts, so buyback routes can still be
            // registered from the deployer (script/SetBurnerRoutes.s.sol) before the handover completes.
            if (useBurner) burner.transferOwnership(owner);
        }

        vm.stopBroadcast();

        o = Out(
            address(escrow), address(hook), address(locker), address(buyback), address(factory), address(launchDeployer),
            address(executor), address(foundation), address(router), address(swapAndBuy), o.mockUsdt, address(burner)
        );
        _write(o);
    }

    function _deployBurner(LoongLaunchFactory factory) internal returns (LoongBuybackBurner) {
        string memory b = ".buybackBurner";
        LoongBuybackBurner.Params memory p = LoongBuybackBurner.Params({
            chunk: _u(string.concat(b, ".chunkWei")),
            minBuy: _u(string.concat(b, ".minBuyWei")),
            minInterval: vm.parseJsonUint(json, string.concat(b, ".minIntervalSeconds")),
            tip: _u(string.concat(b, ".tipWei")),
            maxDeviationBps: vm.parseJsonUint(json, string.concat(b, ".maxDeviationBps")),
            driftBpsPerHour: vm.parseJsonUint(json, string.concat(b, ".driftBpsPerHour")),
            launchDelay: vm.parseJsonUint(json, string.concat(b, ".launchDelaySeconds")),
            openAccess: vm.parseJsonBool(json, string.concat(b, ".openAccess"))
        });
        LoongBuybackBurner impl = new LoongBuybackBurner();
        bytes memory init = abi.encodeCall(
            LoongBuybackBurner.initialize,
            (
                deployer,
                _addr(string.concat(b, ".keeper")),
                factory,
                IUniversalRouterLike(vm.parseJsonAddress(json, ".infinity.universalRouter")),
                vm.parseJsonAddress(json, ".infinity.wbnb"),
                p
            )
        );
        return LoongBuybackBurner(payable(address(new ERC1967Proxy(address(impl), init))));
    }

    function _write(Out memory o) internal {
        string memory k = "d";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "fromBlock", block.number);
        vm.serializeAddress(k, "feeEscrow", o.escrow);
        vm.serializeAddress(k, "hook", o.hook);
        vm.serializeAddress(k, "locker", o.locker);
        vm.serializeAddress(k, "buybackVault", o.buyback);
        vm.serializeAddress(k, "launchDeployer", o.deployer_);
        vm.serializeAddress(k, "graduationExecutor", o.executor);
        vm.serializeAddress(k, "platformTokenVault", o.foundationVault);
        vm.serializeAddress(k, "launchAndBuy", o.launchAndBuy);
        vm.serializeAddress(k, "swapAndBuy", o.swapAndBuy);
        vm.serializeAddress(k, "mockUsdt", o.mockUsdt);
        vm.serializeAddress(k, "buybackBurner", o.buybackBurner);
        string memory out = vm.serializeAddress(k, "factory", o.factory);
        string memory path = string.concat("../deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
        console2.log("wrote", path);
        console2.log("factory", o.factory);
    }
}
