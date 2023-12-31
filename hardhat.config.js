require("@nomicfoundation/hardhat-chai-matchers");
require('solidity-coverage');
require("@nomiclabs/hardhat-ethers");
require("@nomicfoundation/hardhat-toolbox");
/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.9",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1000,
      },
    },
  },
};