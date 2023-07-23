const { expect } = require("chai");

describe("Token contract", function () {
  it("Deployment should assign the total supply of tokens to the owner", async function () {
    //A Signer in ethers.js is an object that represents an Ethereum account. It's used to send transactions to contracts and other accounts. Here we're getting a list of the accounts in the node we're connected to, which in this case is Hardhat Network, and we're only keeping the first one.
    const [owner] = await ethers.getSigners();

    //A ContractFactory in ethers.js is an abstraction used to deploy new smart contracts, so Token here is a factory for instances of our token contract.
    const Token = await ethers.getContractFactory("Token");

    //Calling deploy() on a ContractFactory will start the deployment, and return a Promise that resolves to a Contract. This is the object that has a method for each of your smart contract functions.
    const hardhatToken = await Token.deploy("kirpi","KRP",100000);

    
    const ownerBalance = await hardhatToken.balanceOf(owner.address);
    console.log(ownerBalance.toString());
    expect(await hardhatToken.totalSupply()).to.equal(ownerBalance);
  });
});