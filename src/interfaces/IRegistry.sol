// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IRegistry {
    event AccountCreated(
        address account,
        address tokenContract,
        uint256 tokenId
    );

    function createAccount(address tokenContract, uint256 tokenId)
        external
        returns (address);

    function account(address tokenContract, uint256 tokenId)
        external
        view
        returns (address);
}
