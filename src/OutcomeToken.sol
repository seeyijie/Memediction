// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

//
contract OutcomeToken is ERC20 {
    constructor(string memory _name) ERC20(_name, _name) {
        // Total supply of 1 million tokens
        _mint(msg.sender, 1e6 * 1e18);
    }
}
