#!/bin/bash
#
# Copyright IBM Corp. All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
export PATH=./bin:${PWD}:$PATH
export FABRIC_CFG_PATH=${PWD}
export VERBOSE=false

function dkcl(){
        CONTAINER_IDS=$(docker ps -aq)
	echo
        if [ -z "$CONTAINER_IDS" -o "$CONTAINER_IDS" = " " ]; then
                echo "========== No containers available for deletion =========="
        else
                docker rm -f $CONTAINER_IDS
        fi
	echo
}

function dkrm(){
        DOCKER_IMAGE_IDS=$(docker images | grep "dev\|none\|test-vp\|peer[0-9]-" | awk '{print $3}')
	echo
        if [ -z "$DOCKER_IMAGE_IDS" -o "$DOCKER_IMAGE_IDS" = " " ]; then
		echo "========== No images available for deletion ==========="
        else
                docker rmi -f $DOCKER_IMAGE_IDS
        fi
	echo
}

function restartNetwork() {
	echo

  #teardown the network and clean the containers and intermediate images
	docker-compose -f ./docker-compose.yaml down
	dkcl
	dkrm

   #Cleanup the stores
	rm -rf ./fabric-client-kv-*
  
	generateCerts
  replacePrivateKey
  generateChannelArtifacts

  
	#Start the network
	docker-compose -f ./docker-compose.yaml up -d
	echo
}

function installNodeModules() {
	echo
	if [ -d node_modules ]; then
		echo "============== node modules installed already ============="
	else
		echo "============== Installing node modules ============="
		npm install
	fi
	echo
}

function generateCerts() {
  which cryptogen
  if [ "$?" -ne 0 ]; then
    echo "cryptogen tool not found. exiting"
    exit 1
  fi
  echo "##### Generate certificates using cryptogen tool #########"

  if [ -d "./crypto-config" ]; then
    rm -Rf ./crypto-config
  fi
  cryptogen generate --config=./cryptogen.yaml
  res=$?
  if [ $res -ne 0 ]; then
    echo "Failed to generate certificates..."
    exit 1
  fi
  echo
}
CHANNEL_NAME="bankchannel"
# Generate orderer genesis block and channel configuration transaction with configtxgen
function generateChannelArtifacts() {
  which configtxgen
  if [ "$?" -ne 0 ]; then
    echo "configtxgen tool not found. exiting"
    exit 1
  fi
  rm -Rf ./crypto-config/genesis.block
  rm -Rf ./crypto-config/$CHANNEL_NAME.tx
  rm -Rf ./crypto-config/Bank1MSPanchors.tx
  rm -Rf ./crypto-config/Bank2MSPanchors.tx
  echo "#########  Generating Orderer Genesis block ##############"
  configtxgen -profile TwoOrgsOrdererGenesis -outputBlock ./crypto-config/genesis.block
  res=$?
  if [ $res -ne 0 ]; then
    echo "Failed to generate orderer genesis block..."
    exit 1
  fi
  echo
  echo "### Generating channel configuration transaction 'channel.tx' ###"
  configtxgen -profile TwoOrgsChannel -outputCreateChannelTx ./crypto-config/bankchannel.tx -channelID $CHANNEL_NAME
  res=$?
  if [ $res -ne 0 ]; then
    echo "Failed to generate channel configuration transaction..."
    exit 1
  fi

  echo
  echo "#################################################################"
  echo "#######    Generating anchor peer update for Org1MSP   ##########"
  echo "#################################################################"
  set -x
  configtxgen -profile TwoOrgsChannel -outputAnchorPeersUpdate ./crypto-config/Bank1MSPanchors.tx -channelID $CHANNEL_NAME -asOrg Bank1MSP
  res=$?
  set +x
  if [ $res -ne 0 ]; then
    echo "Failed to generate anchor peer update for Org1MSP..."
    exit 1
  fi

  echo
  echo "#################################################################"
  echo "#######    Generating anchor peer update for Org2MSP   ##########"
  echo "#################################################################"
  set -x
  configtxgen -profile TwoOrgsChannel -outputAnchorPeersUpdate ./crypto-config/Bank2MSPanchors.tx -channelID $CHANNEL_NAME -asOrg Bank2MSP
  res=$?
  set +x
  if [ $res -ne 0 ]; then
    echo "Failed to generate anchor peer update for Org2MSP..."
    exit 1
  fi
  echo
}
function replacePrivateKey() {
  # sed on MacOSX does not support -i flag with a null extension. We will use
  # 't' for our back-up's extension and delete it at the end of the function
  ARCH=$(uname -s | grep Darwin)
  if [ "$ARCH" == "Darwin" ]; then
    OPTS="-it"
  else
    OPTS="-i"
  fi
  if [ -d "./network-config.yaml" ]; then
    rm -Rf ./network-config.yaml
  fi
  # Copy the template to the file that will be modified to add the private key
  cp network-config-template.yaml network-config.yaml

  # The next steps will replace the template's contents with the
  # actual values of the private key file names for the two CAs.
  CURRENT_DIR=$PWD
  cd ./crypto-config/peerOrganizations/bank1.co.in/users/Admin@bank1.co.in/msp/keystore/
  PRIV_KEY=$(ls *_sk)
  cd "$CURRENT_DIR"
  sed $OPTS "s/ORG1_PRIVATE_KEY/${PRIV_KEY}/g" network-config.yaml

  CURRENT_DIR=$PWD
  cd ./crypto-config/peerOrganizations/bank2.azure.com/users/Admin@bank2.azure.com/msp/keystore/
  PRIV_KEY=$(ls *_sk)
  cd "$CURRENT_DIR"
  sed $OPTS "s/ORG2_PRIVATE_KEY/${PRIV_KEY}/g" network-config.yaml

  cp docker-compose-template.yaml docker-compose.yaml

  # The next steps will replace the template's contents with the
  # actual values of the private key file names for the two CAs.
  CURRENT_DIR=$PWD
  cd ./crypto-config/peerOrganizations/bank1.co.in/ca/
  PRIV_KEY=$(ls *_sk)
  cd "$CURRENT_DIR"
  sed $OPTS "s/CA1_PRIVATE_KEY/${PRIV_KEY}/g" docker-compose.yaml


  CURRENT_DIR=$PWD
  cd ./crypto-config/peerOrganizations/bank2.azure.com/ca/
  PRIV_KEY=$(ls *_sk)
  cd "$CURRENT_DIR"
  sed $OPTS "s/CA2_PRIVATE_KEY/${PRIV_KEY}/g" docker-compose.yaml
  # If MacOSX, remove the temporary backup of the docker-compose file
  if [ "$ARCH" == "Darwin" ]; then
    rm docker-compose-e2e.yamlt
  fi
}

restartNetwork
installNodeModules

PORT=4000 node app
