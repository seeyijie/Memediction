#!/bin/bash

check_anvil_running() {
  if lsof -i:8545 >/dev/null; then
    return 0
  else
    return 1
  fi
}

if check_anvil_running; then
  echo "Anvil is already running. Skipping Anvil startup..."
else
  echo "Starting Anvil..."

  # Run anvil in the background
  anvil &

  ANVIL_PID=$!

  sleep 3

  RPC_URL="http://127.0.0.1:8545"
  BLOCK_CHECK=$(cast block --rpc-url $RPC_URL)

  if [[ $BLOCK_CHECK == *"error"* ]]; then
    echo "Failed to connect to Anvil. Exiting..."
    # Kill the anvil process if started in this script
    kill $ANVIL_PID
    exit 1
  else
    echo "Anvil is running. Proceeding with the script..."
  fi
fi


# Deploy the contracts, setup the hooks and start initializing
forge script script/V4Deployer.s.sol:V4Deployer --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast && forge script script/HookMiningSample.s.sol:HookMiningSample --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast
