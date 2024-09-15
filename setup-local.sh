#!/bin/bash

check_anvil_running() {
  if lsof -i:8545 >/dev/null; then
    return 0  # Anvil is already running
  else
    return 1  # Anvil is not running
  fi
}

kill_anvil() {
  echo "Stopping existing Anvil..."
  lsof -ti:8545 | xargs kill -9
}

RESTART_ANVIL=0

while [[ "$1" != "" ]]; do
  case $1 in
    --restart ) RESTART_ANVIL=1
                ;;
  esac
  shift
done

if check_anvil_running; then
  if [[ $RESTART_ANVIL -eq 1 ]]; then
    kill_anvil
    echo "Restarting Anvil..."
    anvil & > /dev/null # redirect stdout to /dev/null
    ANVIL_PID=$!
    sleep 3
  else
    echo "Anvil is already running. Skipping Anvil startup..."
  fi
else
  echo "Starting Anvil..."
  anvil &
  ANVIL_PID=$!
  sleep 3
fi

RPC_URL="http://127.0.0.1:8545"
BLOCK_CHECK=$(cast block --rpc-url $RPC_URL)

if [[ $BLOCK_CHECK == *"error"* ]]; then
  echo "Failed to connect to Anvil. Exiting..."
  if [[ -n "$ANVIL_PID" ]]; then
    kill $ANVIL_PID
  fi
  exit 1
else
  echo "Anvil is running. Proceeding with the script..."
fi


# Deploy the contracts, setup the hooks and start initializing
forge compile && forge script script/V4Deployer.s.sol:V4Deployer --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast && forge script script/HookMiningSample.s.sol:HookMiningSample --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast
