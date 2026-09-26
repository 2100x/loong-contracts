// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LoongLaunchFactory} from "../src/LoongLaunchFactory.sol";
import {LaunchAndBuy} from "../src/LaunchAndBuy.sol";
import {LoongFoundationVault} from "../src/LoongFoundationVault.sol";
import {LoongBuybackBurner} from "../src/LoongBuybackBurner.sol";
import {LoongVanity} from "./LoongVanity.sol";

/**
 * TESTNET ONLY: the buyback-burner trial on the separate stack in deployments/97-burner.json. Launches a test
 * $LOONG on the tiny test config, points the burner at it, switches it on, and funds the vault as if fees had
 * accumulated. The pokes themselves come from the keeper (backend/app/keeper.py) over the following minutes.
 *
 *   DEPLOYER_PK=... forge script script/BurnerTrial.s.sol --rpc-url $RPC --broadcast --slow
 */
contract BurnerTrial is Script {
    uint256 constant TEST_CONFIG = 1; // 0.1 BNB graduation, testnet only

    function run() external {
        require(block.chainid == 97, "testnet only");
        string memory d = vm.readFile("../deployments/97-burner.json");
        LoongLaunchFactory factory = LoongLaunchFactory(payable(vm.parseJsonAddress(d, ".factory")));
        LaunchAndBuy router = LaunchAndBuy(payable(vm.parseJsonAddress(d, ".launchAndBuy")));
        LoongFoundationVault vault = LoongFoundationVault(payable(vm.parseJsonAddress(d, ".platformTokenVault")));
        LoongBuybackBurner burner = LoongBuybackBurner(payable(vm.parseJsonAddress(d, ".buybackBurner")));
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address me = vm.addr(pk);

        LoongLaunchFactory.TokenParams memory p;
        p.name = "Loong (test)";
        p.symbol = "LOONG";
        p.description = "Testnet stand-in for the platform token: buyback-and-burn trial.";
        p.creatorFeeRecipient = me;
        p.buybackEnabled = true;
        p.expectedEconomics = factory.previewLaunchEconomics(TEST_CONFIG, address(0));
        p.salt = LoongVanity.mine(factory, p, TEST_CONFIG, address(0), me);

        vm.startBroadcast(pk);
        (address token,,) = router.launchAndBuy{value: 0.003 ether}(p, TEST_CONFIG, address(0), 0.003 ether, 1, me, false);
        burner.setLoong(token);
        vault.deposit{value: 0.02 ether}(address(0), 0.02 ether);
        burner.setPaused(false);
        vm.stopBroadcast();
        console2.log("LOONG", token);
        console2.log("burner paused", burner.paused());
    }
}
