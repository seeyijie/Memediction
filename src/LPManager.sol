// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import "./PredictionMarketsAMM.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract LPManager is Initializable, OwnableUpgradeable {
    address[] public managedContracts;

    function initialize() public initializer {
        __Ownable_init(); // Initialize Ownable
    }

    // deploy and mint corresponding erc-20 tokens, add single-sided LP to the pool
    function deployAndInitializeManagedContract(IPoolManager _poolManager) public onlyOwner {
        PredictionMarketsAMM managedContract = new PredictionMarketsAMM();
//        managedContract.initialize(_poolManager); // Pass the IPoolManager instance
        managedContracts.push(address(managedContract));
    }

    function getManagedContracts() public view returns (address[] memory) {
        return managedContracts;
    }
}
