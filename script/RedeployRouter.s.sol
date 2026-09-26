// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LoongLaunchFactory} from "../src/LoongLaunchFactory.sol";
import {LaunchAndBuy} from "../src/LaunchAndBuy.sol";
import {SwapAndBuy, IUniversalRouter} from "../src/SwapAndBuy.sol";

/// Replaces the launch-and-buy router (SwapAndBuy is left as is) and points the factory's trusted forwarder at it. The router holds no
/// state, so the old one simply stops being able to launch. On mainnet the owner is the Safe: there this
/// script only deploys, and the setLaunchForwarder call goes through the Safe.
contract RedeployRouter is Script {
    function run() external {
        string memory path = string.concat("../deployments/", vm.toString(block.chainid), ".json");
        LoongLaunchFactory factory = LoongLaunchFactory(payable(vm.parseJsonAddress(vm.readFile(path), ".factory")));
        uint256 pk = vm.envUint("DEPLOYER_PK");
        vm.startBroadcast(pk);
        // Same Universal Router the deployed SwapAndBuy uses (per network).
        IUniversalRouter ur = SwapAndBuy(payable(vm.parseJsonAddress(vm.readFile(path), ".swapAndBuy"))).universalRouter();
        LaunchAndBuy router = new LaunchAndBuy(factory, ur, factory.owner());
        if (factory.owner() == vm.addr(pk)) factory.setLaunchForwarder(address(router));
        vm.stopBroadcast();
        require(block.chainid == 56 || factory.launchForwarder() == address(router), "forwarder not switched");
        vm.writeJson(vm.toString(address(router)), path, ".launchAndBuy");
        console2.log("launchAndBuy", address(router));
    }
}
