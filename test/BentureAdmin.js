const { ethers } = require("hardhat");
const { expect } = require("chai");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");

describe("Benture Admin Token", () => {
    let token;
    let adminToken;
    let factory;
    let benture;
    let factorySigner;
    let rummy;
    let zeroAddress = ethers.constants.AddressZero;
    let parseEther = ethers.utils.parseEther;

    // Deploy all contracts before each test suite
    beforeEach(async () => {
        [ownerAcc, clientAcc1, clientAcc2] = await ethers.getSigners();

        // Deploy dividend-distribution contract
        let bentureTx = await ethers.getContractFactory("Benture");
        benture = await bentureTx.deploy();
        await benture.deployed();

        // Deploy a factory contract
        let factoryTx = await ethers.getContractFactory("PayableFactory");
        factory = await factoryTx.deploy(benture.address);
        await factory.deployed();

        await benture.setFactoryAddress(factory.address);

        // Deploy an admin token (ERC721)
        let adminTx = await ethers.getContractFactory("BentureAdmin");
        adminToken = await adminTx.deploy(factory.address);
        await adminToken.deployed();

        // Create new ERC20 and ERC721 and assign them to caller (owner)
        await factory.createERC20Token(
            "Dummy",
            "DMM",
            18,
            true,
            1_000_000,
            // Provide the address of the previously deployed ERC721
            adminToken.address
        );

        // Get the address of the last ERC20 token produced in the factory
        tokenAddress = await factory.lastProducedToken();
        token = await ethers.getContractAt(
            "BentureProducedToken",
            tokenAddress
        );

        // Deploy another "empty" contract to use its address
        let rummyTx = await ethers.getContractFactory("Rummy");
        rummy = await rummyTx.deploy();
        await rummy.deployed();

        // Make factory contract a signer

        factorySigner = await ethers.getImpersonatedSigner(factory.address);

        // Provide some ether to the factory contract to be able to send transactions
        await ownerAcc.sendTransaction({
            to: factory.address,
            value: parseEther("1"),
        });
    });

    describe("Constructor", () => {
        it("Should initialize with correct name and symbol", async () => {
            let tx = await ethers.getContractFactory("BentureAdmin");
            let adminTokne = await tx.deploy(factory.address);
        });

        it("Should fail to initialize with zero factory address", async () => {
            let tx = await ethers.getContractFactory("BentureAdmin");
            await expect(tx.deploy(zeroAddress)).to.be.revertedWithCustomError(
                adminToken,
                "InvalidFactoryAddress"
            );
        });
    });

    describe("Getters", () => {
        it("Should check that provided address owns admin token", async () => {
            expect(await adminToken.name()).to.equal("Benture Manager Token");
            expect(await adminToken.symbol()).to.equal("BMNG");
        });

        it("Should fail to check that zero address owns admin token", async () => {
            // It should not revert
            await expect(
                adminToken.checkOwner(zeroAddress)
            ).to.be.revertedWithCustomError(adminToken, "InvalidUserAddress");
        });

        it("Should verify that user controls provided ERC20 token", async () => {
            expect(
                await adminToken.verifyAdminToken(
                    ownerAcc.address,
                    token.address
                )
            ).to.equal(true);
            expect(
                await adminToken.verifyAdminToken(
                    clientAcc1.address,
                    token.address
                )
            ).to.equal(false);
        });

        it("Should fail to verify that zero address controls provided ERC20 token", async () => {
            await expect(
                adminToken.verifyAdminToken(zeroAddress, token.address)
            ).to.be.revertedWithCustomError(adminToken, "InvalidUserAddress");
        });

        it("Should fail to verify that user controls provided token with zero address", async () => {
            await expect(
                adminToken.verifyAdminToken(clientAcc1.address, zeroAddress)
            ).to.be.revertedWithCustomError(adminToken, "InvalidTokenAddress");
        });

        it("Should get the address of controlled ERC20 token by admin token ID", async () => {
            expect(await adminToken.getControlledAddressById(1)).to.equal(
                token.address
            );
        });

        it("Should fail to get the address of controlled ERC20 token by invalid admin token ID", async () => {
            await expect(
                adminToken.getControlledAddressById(777)
            ).to.be.revertedWithCustomError(adminToken, "NoControlledToken");
        });

        it("Should get the address of the factory", async () => {
            expect(await adminToken.getFactory()).to.equal(factory.address);
        });

        it("Should get the list of all admin tokens of the admin", async () => {
            // First, admin has only one admin token
            let tokenIds = await adminToken.getAdminTokenIds(ownerAcc.address);
            expect(tokenIds.length).to.eq(1);
            await factory.createERC20Token(
                "Dummy",
                "DMM",
                18,
                true,
                1_000_000,
                adminToken.address
            );
            tokenIds = await adminToken.getAdminTokenIds(ownerAcc.address);
            expect(tokenIds.length).to.eq(2);
        });

        it("Should fail to get the list of admin tokens for zero address", async () => {
            await expect(
                adminToken.getAdminTokenIds(zeroAddress)
            ).to.be.revertedWithCustomError(adminToken, "InvalidAdminAddress");
        });

        it("Should verify that admin controlls several projects", async () => {
            await factory.createERC20Token(
                "Dummy",
                "DMM",
                18,
                true,
                1_000_000,
                adminToken.address
            );

            newTokenAddress = await factory.lastProducedToken();
            newToken = await ethers.getContractAt(
                "BentureProducedToken",
                newTokenAddress
            );
            expect(
                await adminToken.verifyAdminToken(
                    ownerAcc.address,
                    token.address
                )
            ).to.equal(true);
            expect(
                await adminToken.verifyAdminToken(
                    ownerAcc.address,
                    newToken.address
                )
            ).to.equal(true);
            expect(
                await adminToken.verifyAdminToken(
                    ownerAcc.address,
                    newToken.address
                )
            ).to.equal(true);
            await expect(adminToken.checkOwner(ownerAcc.address)).not.to.be
                .reverted;
        });
    });

    describe("Mint", () => {
        it("Should mint a new admin token and connect it to controlled ERC20 token", async () => {
            let startBalance = await adminToken.balanceOf(clientAcc1.address);
            expect(
                await adminToken
                    .connect(factorySigner)
                    .mintWithERC20Address(clientAcc1.address, rummy.address)
            )
                .to.emit(adminToken, "AdminTokenCreated")
                .withArgs(anyValue, anyValue);
            // Check that ID was connected
            // ID is 2 here bacause ID 1 was minted in beforeEach block
            expect(await adminToken.getControlledAddressById(2)).to.equal(
                rummy.address
            );
            let endBalance = await adminToken.balanceOf(clientAcc1.address);
            expect(endBalance - startBalance).to.equal(1);
        });

        it("Should fail to mint a new admin token to zero address", async () => {
            await expect(
                adminToken
                    .connect(factorySigner)
                    .mintWithERC20Address(zeroAddress, rummy.address)
            ).to.be.revertedWithCustomError(
                adminToken,
                "MintToZeroAddressNotAllowed"
            );
        });

        it("Should fail to mint a new admin token and connect in to zero address", async () => {
            await expect(
                adminToken
                    .connect(factorySigner)
                    .mintWithERC20Address(clientAcc1.address, zeroAddress)
            ).to.be.revertedWithCustomError(adminToken, "InvalidTokenAddress");
        });

        it("Should fail to mint a new admin token to the same account twice", async () => {
            await adminToken
                .connect(factorySigner)
                .mintWithERC20Address(clientAcc1.address, rummy.address);
            await expect(
                adminToken
                    .connect(factorySigner)
                    .mintWithERC20Address(clientAcc1.address, rummy.address)
            ).to.be.revertedWithCustomError(
                adminToken,
                "OnlyOneAdminTokenForProjectToken"
            );
        });

        it("Should fail to mint a new admin token if caller is not a factory", async () => {
            await expect(
                adminToken.mintWithERC20Address(
                    clientAcc1.address,
                    rummy.address
                )
            ).to.be.revertedWithCustomError(adminToken, "CallerIsNotAFactory");
        });
    });

    describe("Burn", () => {
        it("Should burn token with provided ID", async () => {
            await adminToken
                .connect(factorySigner)
                .mintWithERC20Address(clientAcc1.address, rummy.address);
            let startBalance = await adminToken.balanceOf(clientAcc1.address);
            expect(await adminToken.connect(clientAcc1).burn(2))
                .to.emit(adminToken, "AdminTokenBurnt")
                .withArgs(anyValue);
            let endBalance = await adminToken.balanceOf(clientAcc1.address);
            expect(startBalance - endBalance).to.equal(1);
            // Check that user does not have any admin tokens
            await expect(
                adminToken.checkOwner(clientAcc1.address)
            ).to.be.revertedWithCustomError(
                adminToken,
                "UserDoesNotHaveAnAdminToken"
            );
            expect(
                await adminToken.verifyAdminToken(
                    clientAcc1.address,
                    rummy.address
                )
            ).to.equal(false);
            // Check that it is impossible to get the controlled address for burnt admin token
            await expect(
                adminToken.getControlledAddressById(2)
            ).to.be.revertedWithCustomError(adminToken, "NoControlledToken");
        });

        it("Should fail to burn non-existent admin token", async () => {
            await adminToken
                .connect(factorySigner)
                .mintWithERC20Address(clientAcc1.address, rummy.address);
            await expect(
                adminToken.connect(clientAcc1).burn(777)
            ).to.be.revertedWith("ERC721: invalid token ID");
        });

        it("Should fail to burn token if caller is not an owner", async () => {
            await adminToken
                .connect(factorySigner)
                .mintWithERC20Address(clientAcc1.address, rummy.address);
            await expect(
                adminToken.connect(clientAcc2).burn(2)
            ).to.be.revertedWithCustomError(adminToken, "NotAnOwner");
        });

        it("Should burn one of several admin tokens of the user", async () => {
            await factory.createERC20Token(
                "Dummy",
                "DMM",
                18,
                true,
                1_000_000,
                adminToken.address
            );
            // Now owner has 2 admin tokens
            newTokenAddress = await factory.lastProducedToken();
            newToken = await ethers.getContractAt(
                "BentureProducedToken",
                newTokenAddress
            );
            let startBalance = await adminToken.balanceOf(ownerAcc.address);
            expect(startBalance).to.eq(2);
            // Try to burn the second token
            expect(await adminToken.connect(ownerAcc).burn(2))
                .to.emit(adminToken, "AdminTokenBurnt")
                .withArgs(anyValue);
            let endBalance = await adminToken.balanceOf(ownerAcc.address);
            expect(endBalance).to.eq(1);
            // Check that user is still an admin
            expect(
                await adminToken.verifyAdminToken(
                    ownerAcc.address,
                    token.address
                )
            ).to.equal(true);
            // Check that it is impossible to get the controlled address for burnt admin token
            await expect(
                adminToken.getControlledAddressById(2)
            ).to.be.revertedWithCustomError(adminToken, "NoControlledToken");
        });
    });

    describe("Transfer", () => {
        it("Should transfer token with provided ID from one account to another", async () => {
            await adminToken
                .connect(factorySigner)
                .mintWithERC20Address(clientAcc1.address, rummy.address);
            expect(
                await adminToken
                    .connect(clientAcc1)
                    .transferFrom(clientAcc1.address, clientAcc2.address, 2)
            )
                .to.emit(adminToken, "AdminTokenTransferred")
                .withArgs(anyValue, anyValue, 2);
            let firstBalance = await adminToken.balanceOf(clientAcc1.address);
            let secondBalance = await adminToken.balanceOf(clientAcc2.address);
            expect(firstBalance).to.equal(0);
            expect(secondBalance).to.equal(1);
            // Check that the first user does not have any admin tokens
            await expect(
                adminToken.checkOwner(clientAcc1.address)
            ).to.be.revertedWithCustomError(
                adminToken,
                "UserDoesNotHaveAnAdminToken"
            );
            expect(
                await adminToken.verifyAdminToken(
                    clientAcc1.address,
                    rummy.address
                )
            ).to.equal(false);
            // Check that the second user received the token and now has the control
            await adminToken.checkOwner(clientAcc2.address);
            expect(
                await adminToken.verifyAdminToken(
                    clientAcc2.address,
                    rummy.address
                )
            ).to.equal(true);
            // Check that it is still possible to get the controlled token address
            expect(await adminToken.getControlledAddressById(2)).to.equal(
                rummy.address
            );
        });

        it("Should fail to transfer non-existent admin token", async () => {
            await adminToken
                .connect(factorySigner)
                .mintWithERC20Address(clientAcc1.address, rummy.address);
            await expect(
                adminToken
                    .connect(clientAcc1)
                    .transferFrom(clientAcc1.address, clientAcc2.address, 777)
            ).to.be.revertedWith("ERC721: invalid token ID");
        });

        it("Should fail to transfer from zero address", async () => {
            await adminToken
                .connect(factorySigner)
                .mintWithERC20Address(clientAcc1.address, rummy.address);
            await expect(
                adminToken
                    .connect(clientAcc1)
                    .transferFrom(zeroAddress, clientAcc2.address, 2)
            ).to.be.revertedWithCustomError(adminToken, "InvalidUserAddress");
        });

        it("Should fail to transfer to zero address", async () => {
            await adminToken
                .connect(factorySigner)
                .mintWithERC20Address(clientAcc1.address, rummy.address);
            await expect(
                adminToken
                    .connect(clientAcc1)
                    .transferFrom(clientAcc1.address, zeroAddress, 2)
            ).to.be.revertedWithCustomError(adminToken, "InvalidUserAddress");
        });

        it("Should fail to transfer if sender does not have any admin tokens", async () => {
            await adminToken
                .connect(factorySigner)
                .mintWithERC20Address(clientAcc1.address, rummy.address);
            await expect(
                adminToken
                    .connect(ownerAcc)
                    .transferFrom(ownerAcc.address, clientAcc2.address, 2)
            ).to.be.revertedWith(
                "ERC721: caller is not token owner nor approved"
            );
        });
    });
});
