// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// TESTNET ONLY. An 18-decimal stand-in for USDT so ERC-20-quoted launches can be exercised on BSC testnet.
/// Anyone may mint; it has no value by construction.
contract MockUSDT is ERC20 {
    constructor() ERC20("Loong Test USDT", "tUSDT") {}

    function mint(address to, uint256 amount) external {
        require(amount <= 1_000_000 ether, "mint at most 1M per call");
        _mint(to, amount);
    }
}
