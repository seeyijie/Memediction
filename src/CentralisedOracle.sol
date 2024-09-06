// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IOracle} from "./interface/IOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// Adapted from Gnosis PM
// https://github.com/gnosis/pm-contracts/blob/master/contracts/Oracles/CentralizedOracle.sol
contract CentralisedOracle is IOracle, Ownable {
    /*
     *  Events
     */
    event OwnerReplacement(address indexed newOwner);
    event OutcomeAssignment(int outcome);

    /*
     *  Storage
     */
    bytes public ipfsHash; // IPFS description hash

    bool public isSet;
    int public outcome; // 0 is reserved for unresolved

    constructor() Ownable(msg.sender) {}

    /*
     *  Modifiers
     */
    function setOutcome(int _outcome) public onlyOwner {
        require(!isSet, "Outcome already set");
        isSet = true;
        outcome = _outcome;
        emit OutcomeAssignment(outcome);
    }

    function getOutcome() public view override returns (int) {
        return outcome;
    }

    function isOutcomeSet() public view override returns (bool) {
        return isSet;
    }
}
