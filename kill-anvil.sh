#!/bin/bash
echo "Stopping existing Anvil..."
lsof -ti:8545 | xargs kill -9