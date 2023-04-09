// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "erc6551/interfaces/IERC6551Account.sol";

import "openzeppelin-contracts/utils/introspection/IERC165.sol";
import "openzeppelin-contracts/token/ERC721/IERC721.sol";
import "openzeppelin-contracts/token/ERC721/IERC721Receiver.sol";
import "openzeppelin-contracts/token/ERC1155/IERC1155Receiver.sol";
import "openzeppelin-contracts/interfaces/IERC1271.sol";
import "openzeppelin-contracts/utils/cryptography/SignatureChecker.sol";
import "openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import "openzeppelin-contracts/access/AccessControl.sol";

import {BaseAccount, IEntryPoint, UserOperation, IAccount as IERC4337Account} from "account-abstraction/core/BaseAccount.sol";

import "sstore2/utils/Bytecode.sol";

error NotAuthorized();
error InvalidInput();
error AccountLocked();
error ExceedsMaxLockTime();
error InvalidNonce();
error UntrustedImplementation();

contract AccountV2 is
    IERC165,
    IERC1271,
    IERC6551Account,
    IERC721Receiver,
    IERC1155Receiver,
    UUPSUpgradeable,
    BaseAccount
{
    // @dev ERC-4337 entry point
    address immutable _entryPoint;

    // @dev Updated on each transaction
    uint256 _nonce;

    // @dev address that manages upgrade and cross-chain execution settings
    address public guardian;

    // @dev timestamp at which this account will be unlocked
    uint256 public lockedUntil;

    // @dev mapping from cross-chain executor => is trusted
    mapping(address => bool) public trustedExecutors;

    // @dev mapping from implementation => is trusted
    mapping(address => bool) public trustedImplementations;

    // @dev mapping from owner => selector => implementation
    mapping(address => mapping(bytes4 => address)) public overrides;

    // @dev mapping from owner => caller => selector => has permissions
    mapping(address => mapping(address => mapping(bytes4 => bool)))
        public permissions;

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotAuthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert NotAuthorized();
        _;
    }

    modifier onlyAuthorized() {
        if (!isAuthorized(msg.sender, msg.sig)) revert NotAuthorized();
        _;
    }

    modifier onlyUnlocked() {
        if (isLocked()) revert AccountLocked();
        _;
    }

    constructor(address _guardian, address entryPoint_) {
        _entryPoint = entryPoint_;
        guardian = _guardian;
    }

    receive() external payable {
        _handleOverride();
    }

    fallback() external payable onlyUnlocked {
        _handleOverride();
    }

    function executeCall(
        address to,
        uint256 value,
        bytes calldata data
    ) external payable onlyAuthorized onlyUnlocked returns (bytes memory) {
        if (!isAuthorized(msg.sender, msg.sig)) revert NotAuthorized();

        ++_nonce;

        _handleOverride();

        return _call(to, value, data);
    }

    function setOverrides(
        bytes4[] calldata selectors,
        address[] calldata implementations
    ) external onlyOwner onlyUnlocked {
        address _owner = owner();
        if (msg.sender != _owner) revert NotAuthorized();

        if (selectors.length != implementations.length) revert InvalidInput();

        ++_nonce;

        for (uint256 i = 0; i < selectors.length; i++) {
            overrides[_owner][selectors[i]] = implementations[i];
        }
    }

    function grantPermissions(
        bytes4[] calldata selectors,
        address[] calldata implementations
    ) external onlyOwner onlyUnlocked {
        address _owner = owner();
        if (msg.sender != _owner) revert NotAuthorized();

        if (selectors.length != implementations.length) revert InvalidInput();

        ++_nonce;

        for (uint256 i = 0; i < selectors.length; i++) {
            permissions[_owner][implementations[i]][selectors[i]] = true;
        }
    }

    function lock(uint256 _lockedUntil) external onlyOwner onlyUnlocked {
        if (_lockedUntil > block.timestamp + 365 days)
            revert ExceedsMaxLockTime();

        lockedUntil = _lockedUntil;
    }

    function setTrustedImplementation(address implementation, bool trusted)
        external
        notDelegated
        onlyGuardian
    {
        trustedImplementations[implementation] = trusted;
    }

    function setTrustedExecutor(address executor, bool trusted)
        external
        notDelegated
        onlyGuardian
    {
        trustedExecutors[executor] = trusted;
    }

    function setGuardian(address _guardian) external notDelegated onlyGuardian {
        guardian = _guardian;
    }

    function isLocked() public view returns (bool) {
        return lockedUntil > block.timestamp;
    }

    function isValidSignature(bytes32 hash, bytes memory signature)
        external
        view
        returns (bytes4 magicValue)
    {
        _handleOverrideStatic();

        bool isValid = SignatureChecker.isValidSignatureNow(
            owner(),
            hash,
            signature
        );

        if (isValid) {
            return IERC1271.isValidSignature.selector;
        }

        return "";
    }

    function token()
        external
        view
        returns (
            uint256 chainId,
            address tokenContract,
            uint256 tokenId
        )
    {
        address self = address(this);
        uint256 length = self.code.length;
        if (length < 0x60) return (0, address(0), 0);

        return
            abi.decode(
                Bytecode.codeAt(self, length - 0x60, length),
                (uint256, address, uint256)
            );
    }

    function nonce()
        public
        view
        override(BaseAccount, IERC6551Account)
        returns (uint256)
    {
        return _nonce;
    }

    function entryPoint() public view override returns (IEntryPoint) {
        return IEntryPoint(_entryPoint);
    }

    function owner() public view returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = this
            .token();

        if (chainId != block.chainid) return address(0);

        return IERC721(tokenContract).ownerOf(tokenId);
    }

    function isAuthorized(address caller, bytes4 selector)
        public
        view
        returns (bool)
    {
        (uint256 chainId, address tokenContract, uint256 tokenId) = this
            .token();

        address _owner = IERC721(tokenContract).ownerOf(tokenId);

        // authorize token owner
        if (caller == _owner) return true;

        // authorize entrypoint for 4337 transactions
        if (caller == _entryPoint) return true;

        // authorize trusted cross-chain executors if not on native chain
        AccountV2 implementation = AccountV2(payable(_getImplementation()));
        if (chainId != block.chainid && implementation.trustedExecutors(caller))
            return true;

        // authorize caller if owner has granted permissions for function call
        if (permissions[_owner][caller][selector]) return true;

        return false;
    }

    function isTrustedImplementation(address implementation)
        external
        view
        notDelegated
        returns (bool)
    {
        return trustedImplementations[implementation];
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override
        returns (bool)
    {
        bool defaultSupport = interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == type(IERC6551Account).interfaceId ||
            interfaceId == type(IERC4337Account).interfaceId;

        if (defaultSupport) return true;

        // if not supported by default, check override
        _handleOverrideStatic();

        return false;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public view override returns (bytes4) {
        _handleOverrideStatic();

        return this.onERC721Received.selector;
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public view override returns (bytes4) {
        _handleOverrideStatic();

        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public view override returns (bytes4) {
        _handleOverrideStatic();

        return this.onERC1155BatchReceived.selector;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        view
        override
        onlyOwner
    {
        AccountV2 implementation = AccountV2(payable(_getImplementation()));
        if (!implementation.isTrustedImplementation(newImplementation))
            revert UntrustedImplementation();
    }

    function _validateSignature(
        UserOperation calldata userOp,
        bytes32 userOpHash
    ) internal view override returns (uint256 validationData) {
        bool isValid = SignatureChecker.isValidSignatureNow(
            owner(),
            userOpHash,
            userOp.signature
        );

        if (isValid) {
            return 0;
        }

        return 1;
    }

    function _validateAndUpdateNonce(UserOperation calldata userOp)
        internal
        override
    {
        if (_nonce++ != userOp.nonce) revert InvalidNonce();
    }

    function _call(
        address to,
        uint256 value,
        bytes calldata data
    ) internal returns (bytes memory result) {
        bool success;
        (success, result) = to.call{value: value}(data);

        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function _handleOverride() internal returns (bytes memory result) {
        address implementation = overrides[owner()][msg.sig];

        if (implementation != address(0)) {
            result = _call(implementation, msg.value, msg.data);
            assembly {
                return(add(result, 32), mload(result))
            }
        }
    }

    function _callStatic(address to, bytes calldata data)
        internal
        view
        returns (bytes memory result)
    {
        bool success;
        (success, result) = to.staticcall(data);

        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function _handleOverrideStatic()
        internal
        view
        returns (bytes memory result)
    {
        address implementation = overrides[owner()][msg.sig];

        if (implementation != address(0)) {
            result = _callStatic(implementation, msg.data);
            assembly {
                return(add(result, 32), mload(result))
            }
        }
    }
}