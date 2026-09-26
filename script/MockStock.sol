// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Testnet stand-in for a tokenized stock (NVDAB, TSLAB, …): freely mintable, 18 decimals. Never deployed on mainnet.
contract MockStock is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        require(amount <= 1_000_000 ether, "mint at most 1M per call");
        _mint(to, amount);
    }
}
