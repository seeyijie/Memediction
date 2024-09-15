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
        bytes ipfsHash; // Store event details in JSON format
        bool isOutcomeSet;
        int16 outcomeResolution; // -1 by default
        Outcome[] outcomes; // Store outcome tokens in array
        // Store v4 poolIds based on outcome resolution index
        PoolId[] lpPools;
    }

    struct Market {
        Stage stage;
        address creator;
        uint256 createdAtBlock;
        IOracle oracle;
        bytes32 eventId;
        //        uint256 usdmAmountAtSettlement; // Total amount of collateral token underlying the market

        // To remove???
        uint24 fee; // Reflected in LP pool fee
    }

    function initializeMarket(uint24 _fee, bytes memory _eventIpfsHash, OutcomeDetails[] calldata _outcomeDetails)
        external
        returns (bytes32 marketId, PoolId[] memory, Outcome[] memory, IOracle);

    function startMarket(bytes32 marketId) external;

    function settle(bytes32 marketId, int16 outcome) external;
}
