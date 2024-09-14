#!/bin/bash

# Background task
anvil &

# Save the PID of the anvil process
ANVIL_PID=$!

# Wait for 3 seconds
sleep 3

# Check if the blockchain is running using `cast`
RPC_URL="http://127.0.0.1:8545"
BLOCK_CHECK=$(cast block --rpc-url $RPC_URL)

if [[ $BLOCK_CHECK == *"error"* ]]; then
  echo "Failed to connect to Anvil. Exiting..."
  # Kill the anvil process
  kill $ANVIL_PID
  exit 1
else
  echo "Anvil is running. Proceeding with the script..."
fi

# Deploy the contracts, setup the hooks and start initializing
forge script script/V4Deployer.s.sol:V4Deployer --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast && forge script script/HookMiningSample.s.sol:HookMiningSample --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast
