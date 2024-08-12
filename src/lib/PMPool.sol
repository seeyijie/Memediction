// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { PredictionMarketsAMM } from '../PredictionMarketsAMM.sol';

// Prediction Market LP utilizing v4 hooks
library PMSettlement {
    struct PMMEvent {
        PredictionMarketsAMM[] pools;
        string description;
    }

    /**
    * @notice Settles the pool by transferring all tokens to the addresses that own the winning tokens
    */
    function settle(PMMEvent calldata events) public {}


}
