// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IOracle} from "./IOracle.sol";

interface IPredictionMarket {
    // Finite State Machine
    enum Stage {
        CREATED, // Created but not started
        STARTED, // Event has started (open to buy / sell)
        RESOLVED, // Market resolved
        ENDED, // Payouts distributed
        CANCELED
    }

    struct OutcomeDetails {
        bytes ipfsDetails; // Store description, image, etc in JSON format
        string name; // Outcome token name
    }

    struct Outcome {
        Currency outcomeToken; // Currency used instead of ERC20
        OutcomeDetails details; // Supplementary details
    }

    struct Event {
        Currency collateralToken;

        string question; // Revisit to restrict length (gas fees)
        bool isOutcomeSet;
        int16 outcomeResolution; // -1 by default

        Outcome[] outcomes; // Store outcome tokens in array

        // Store v4 poolIds based on outcome resolution index
        PoolId[] lpPools;
    }

    struct Market {
        Stage stage;
        address creator;
        uint createdAtBlock;
        bytes32 eventId;
        IOracle oracle;
        uint24 fee; // Reflected in LP pool fee
    }

    function initializeMarket(uint24 _fee, string calldata _question, OutcomeDetails[] calldata _outcomes) external;

    // function settle() external;
}
