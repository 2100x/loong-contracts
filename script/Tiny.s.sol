// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LoongLaunchFactory} from "../src/LoongLaunchFactory.sol";
import {LaunchAndBuy} from "../src/LaunchAndBuy.sol";
import {LoongVanity} from "./LoongVanity.sol";

/// TESTNET: the cheapest possible launch (0.002 BNB opening buy on the 0.1 BNB test config). Used to
/// exercise the backend's indexer and push without spending faucet funds.
contract Tiny is Script {
    function run() external {
        require(block.chainid != 56, "testnet only");
        string memory d = vm.readFile(string.concat("../deployments/", vm.toString(block.chainid), ".json"));
        LoongLaunchFactory factory = LoongLaunchFactory(payable(vm.parseJsonAddress(d, ".factory")));
        LaunchAndBuy router = LaunchAndBuy(payable(vm.parseJsonAddress(d, ".launchAndBuy")));
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address me = vm.addr(pk);
        LoongLaunchFactory.TokenParams memory p;
        p.name = vm.envOr("NAME", string("Loong Tiny"));
        p.symbol = string.concat("TNY", vm.toString(block.timestamp % 10000));
        p.description = "Backend push test.";
        p.creatorFeeRecipient = me;
        p.buybackEnabled = true;
        p.expectedEconomics = factory.previewLaunchEconomics(1, address(0));
        p.salt = LoongVanity.mine(factory, p, 1, address(0), me);
        vm.broadcast(pk);
        (address token,,) = router.launchAndBuy{value: 0.002 ether}(p, 1, address(0), 0.002 ether, 1, me, false);
        console2.log("token", token);
    }
}
