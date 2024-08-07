// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { PredictionMarketsAMM } from '../PredictionMarketsAMM.sol';

// Prediction Market LP utilizing v4 hooks
library PMSettlement {
    struct PMEvent {
        PredictionMarketsAMM[] pools;
        string description;
    }

    mapping(string => PMMEvent) public events;
    /**
    * @notice Settles the pool by transferring all tokens to the addresses that own the winning tokens
    */
    function settle(PMMEvent[] events) public {
        uint256[2] memory balancesFromPoolA = getPoolBalances(poolAddress0, erc20Token0, erc20Token1);
        uint256[2] memory balances1 = getPoolBalances(poolAddress1, erc20Token0, erc20Token1);
        uint256[2] memory balances;
        balances[0] = balances0[0] + balances1[0];
        balances[1] = balances0[1] + balances1[1];
        erc20Token0.transfer(poolAddress0, balances[0]);
        erc20Token1.transfer(poolAddress0, balances[1]);
    }


}
