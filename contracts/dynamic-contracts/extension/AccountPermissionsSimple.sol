// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/// @author thirdweb

import "../../extension/interface/IAccountPermissionsSimple.sol";
import "../../openzeppelin-presets/utils/cryptography/EIP712.sol";
import "../../openzeppelin-presets/utils/structs/EnumerableSet.sol";

library AccountPermissionsStorage {
    bytes32 public constant ACCOUNT_PERMISSIONS_STORAGE_POSITION = keccak256("account.permissions.storage");

    struct Data {
        /// @dev Map from address => whether the address is an admin.
        mapping(address => bool) isAdmin;
        /// @dev Map from signer address => active restrictions for that signer.
        mapping(address => IAccountPermissionsSimple.SignerPermissionsStatic) signerPermissions;
        /// @dev Map from signer address => approved target the signer can call using the account contract.
        mapping(address => EnumerableSet.AddressSet) approvedTargets;
        /// @dev Mapping from a signed request UID => whether the request is processed.
        mapping(bytes32 => bool) executed;
    }

    function accountPermissionsStorage() internal pure returns (Data storage accountPermissionsData) {
        bytes32 position = ACCOUNT_PERMISSIONS_STORAGE_POSITION;
        assembly {
            accountPermissionsData.slot := position
        }
    }
}

abstract contract AccountPermissionsSimple is IAccountPermissionsSimple, EIP712 {
    using ECDSA for bytes32;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 private constant TYPEHASH =
        keccak256(
            "SignerPermissionRequest(address signer,address[] approvedTargets,uint256 nativeTokenLimitPerTransaction,uint128 permissionStartTimestamp,uint128 permissionEndTimestamp,uint128 reqValidityStartTimestamp,uint128 reqValidityEndTimestamp,bytes32 uid)"
        );

    modifier onlyAdmin() virtual {
        require(isAdmin(msg.sender), "AccountPermissions: caller is not an admin");
        _;
    }

    /*///////////////////////////////////////////////////////////////
                            External functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds / removes an account as an admin.
    function setAdmin(address _account, bool _isAdmin) external virtual onlyAdmin {
        _setAdmin(_account, _isAdmin);
    }

    /// @notice Sets the permissions for a given signer.
    function setPermissionsForSigner(SignerPermissionRequest calldata _req, bytes calldata _signature) external {
        address targetSigner = _req.signer;
        require(!isAdmin(targetSigner), "AccountPermissions: signer is already an admin");

        require(
            _req.reqValidityStartTimestamp <= block.timestamp && block.timestamp < _req.reqValidityEndTimestamp,
            "AccountPermissions: invalid request validity period"
        );

        (bool success, address signer) = verifySignerPermissionRequest(_req, _signature);
        require(success, "AccountPermissions: invalid signature");

        AccountPermissionsStorage.Data storage data = AccountPermissionsStorage.accountPermissionsStorage();
        data.executed[_req.uid] = true;

        data.signerPermissions[targetSigner] = SignerPermissionsStatic(
            _req.nativeTokenLimitPerTransaction,
            _req.permissionStartTimestamp,
            _req.permissionEndTimestamp
        );

        address[] memory currentTargets = data.approvedTargets[targetSigner].values();
        uint256 currentLen = currentTargets.length;

        for (uint256 i = 0; i < currentLen; i += 1) {
            data.approvedTargets[targetSigner].remove(currentTargets[i]);
        }

        uint256 len = _req.approvedTargets.length;
        for (uint256 i = 0; i < len; i += 1) {
            data.approvedTargets[targetSigner].add(_req.approvedTargets[i]);
        }

        _afterSignerPermissionsUpdate(_req);

        emit SignerPermissionsUpdated(signer, targetSigner, _req);
    }

    /*///////////////////////////////////////////////////////////////
                            View functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns whether the given account is an admin.
    function isAdmin(address _account) public view virtual returns (bool) {
        AccountPermissionsStorage.Data storage data = AccountPermissionsStorage.accountPermissionsStorage();
        return data.isAdmin[_account];
    }

    /// @notice Returns whether the given account is an active signer on the account.
    function isActiveSigner(address signer) external view returns (bool) {
        AccountPermissionsStorage.Data storage data = AccountPermissionsStorage.accountPermissionsStorage();
        SignerPermissionsStatic memory permissions = data.signerPermissions[signer];

        return
            permissions.permissionStartTimestamp <= block.timestamp &&
            block.timestamp < permissions.permissionEndTimestamp &&
            data.approvedTargets[signer].length() > 0;
    }

    /// @notice Returns the restrictions under which a signer can use the smart wallet.
    function getPermissionsForSigner(address signer) external view returns (SignerPermissions memory) {
        AccountPermissionsStorage.Data storage data = AccountPermissionsStorage.accountPermissionsStorage();
        SignerPermissionsStatic memory permissions = data.signerPermissions[signer];

        return
            SignerPermissions(
                data.approvedTargets[signer].values(),
                permissions.nativeTokenLimitPerTransaction,
                permissions.permissionStartTimestamp,
                permissions.permissionEndTimestamp
            );
    }

    /// @dev Verifies that a request is signed by an authorized account.
    function verifySignerPermissionRequest(SignerPermissionRequest calldata req, bytes calldata signature)
        public
        view
        virtual
        returns (bool success, address signer)
    {
        AccountPermissionsStorage.Data storage data = AccountPermissionsStorage.accountPermissionsStorage();
        signer = _recoverAddress(req, signature);
        success = !data.executed[req.uid] && isAdmin(signer);
    }

    /*///////////////////////////////////////////////////////////////
                        Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Runs after every `changeRole` run.
    function _afterSignerPermissionsUpdate(SignerPermissionRequest calldata _req) internal virtual;

    /// @notice Makes the given account an admin.
    function _setAdmin(address _account, bool _isAdmin) internal virtual {
        AccountPermissionsStorage.Data storage data = AccountPermissionsStorage.accountPermissionsStorage();
        data.isAdmin[_account] = _isAdmin;

        emit AdminUpdated(_account, _isAdmin);
    }

    /// @dev Returns the address of the signer of the request.
    function _recoverAddress(SignerPermissionRequest calldata _req, bytes calldata _signature)
        internal
        view
        virtual
        returns (address)
    {
        return _hashTypedDataV4(keccak256(_encodeRequest(_req))).recover(_signature);
    }

    /// @dev Encodes a request for recovery of the signer in `recoverAddress`.
    function _encodeRequest(SignerPermissionRequest calldata _req) internal pure virtual returns (bytes memory) {
        return
            abi.encode(
                TYPEHASH,
                _req.signer,
                _req.approvedTargets,
                _req.nativeTokenLimitPerTransaction,
                _req.permissionStartTimestamp,
                _req.permissionEndTimestamp,
                _req.reqValidityStartTimestamp,
                _req.reqValidityEndTimestamp,
                _req.uid
            );
    }
}