// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './lib/PMPool.sol';

contract Manager {
    address private owner;
    PMSettlement.PMMEvent[] public events;
    mapping(uint256 => PMSettlement.PMMEvent) public events;

    function sizeOfEvents() public view returns (uint256) {
        return events.length;
    }

    // n-outcomes = n-pools
    // deploy pools with single-sided liquidity
    function deployPools() public {
        // deploy pools
        // configure event
        // configure oracle
    }

    // configure event
    // configure uma(?) oracle
    function configureEvent(string memory description, PredictionMarketsAMM[] pools) private {
        PMSettlement.PMMEvent memory pmEvents = PMSettlement.PMMEvent(pools, description);
        uint256 sizeOfEvents = events.length;
        events[sizeOfEvents] = pmEvents;
        // configure oracle
    }

    function getPoolBalances(address poolAddress, IERC20 erc20Token0, IERC20 erc20Token1) public view returns (uint256[2] memory) {
        // remove liquidity across all pools
        return [erc20Token0.balanceOf(poolAddress), erc20Token1.balanceOf(poolAddress)];
    }

    function settle() public {
        for (uint256 i = 0; i < events.length; i++) {
            PMSettlement.settle(events[i]);
        }
    }
}
