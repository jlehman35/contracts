// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

// Interface
import "./interfaces/IDynamicNFT.sol";

// Base
import "./eip/ERC721AVirtualApproveUpgradeable.sol";

// Lib
import "./lib/CurrencyTransferLib.sol";

// Extensions
import "./extension/NFTMetadata.sol";
import "./extension/SignatureMintERC721Upgradeable.sol";
import "./extension/ContractMetadata.sol";
import "./extension/Ownable.sol";
import "./extension/Royalty.sol";
import "./extension/PrimarySale.sol";
import "./extension/PlatformFee.sol";
import "./extension/Multicall.sol";
import "./extension/PermissionsEnumerable.sol";
import "./extension/DefaultOperatorFiltererUpgradeable.sol";
import "./openzeppelin-presets/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract DynamicNFT is
    IDynamicNFT,
    ContractMetadata,
    Ownable,
    Royalty,
    PrimarySale,
    PlatformFee,
    Multicall,
    PermissionsEnumerable,
    ReentrancyGuardUpgradeable,
    DefaultOperatorFiltererUpgradeable,
    ERC2771ContextUpgradeable,
    NFTMetadata,
    SignatureMintERC721Upgradeable,
    ERC721AUpgradeable
{
    /*///////////////////////////////////////////////////////////////
                                State variables
    //////////////////////////////////////////////////////////////*/

    /// @dev Only TRANSFER_ROLE holders can have tokens transferred from or to them, during restricted transfers.
    bytes32 private constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");
    /// @dev Only MINTER_ROLE holders can sign off on `MintRequest`s.
    bytes32 private constant MINTER_ROLE = keccak256("MINTER_ROLE");
    /// @dev Only METADATA_ROLE holders can update NFT metadata.
    bytes32 private constant METADATA_ROLE = keccak256("METADATA_ROLE");
    /// @dev Only BURN_ROLE holders can burn NFTs without approvals.
    bytes32 private constant BURN_ROLE = keccak256("BURN_ROLE");

    /// @dev Max bps in the thirdweb system.
    uint256 private constant MAX_BPS = 10_000;

    /*///////////////////////////////////////////////////////////////
                        Constructor + initializer
    //////////////////////////////////////////////////////////////*/

    constructor() initializer {}

    /// @dev Initiliazes the contract, like a constructor.
    function initialize(
        address _defaultAdmin,
        string memory _name,
        string memory _symbol,
        string memory _contractURI,
        address[] memory _trustedForwarders,
        address _saleRecipient,
        address _royaltyRecipient,
        uint128 _royaltyBps,
        uint128 _platformFeeBps,
        address _platformFeeRecipient
    ) external initializer {
        // Initialize inherited contracts, most base-like -> most derived.
        __ERC2771Context_init(_trustedForwarders);
        __ERC721A_init(_name, _symbol);
        __DefaultOperatorFilterer_init();

        _setupContractURI(_contractURI);
        _setupOwner(_defaultAdmin);
        _setOperatorRestriction(true);

        _setupRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _setupRole(MINTER_ROLE, _defaultAdmin);
        _setupRole(TRANSFER_ROLE, _defaultAdmin);
        _setupRole(TRANSFER_ROLE, address(0));

        _setupRole(METADATA_ROLE, _defaultAdmin);
        _setRoleAdmin(METADATA_ROLE, METADATA_ROLE);

        _setupRole(BURN_ROLE, _defaultAdmin);
        _setRoleAdmin(BURN_ROLE, BURN_ROLE);

        _setupPlatformFeeInfo(_platformFeeRecipient, _platformFeeBps);
        _setupDefaultRoyaltyInfo(_royaltyRecipient, _royaltyBps);
        _setupPrimarySaleRecipient(_saleRecipient);
    }

    /*///////////////////////////////////////////////////////////////
                        ERC 165 / 721 / 2981 logic
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the URI for a given tokenId.
    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        return _getTokenURI(_tokenId);
    }

    /// @dev See ERC 165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721AUpgradeable, IERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId) || type(IERC2981).interfaceId == interfaceId;
    }

    /*///////////////////////////////////////////////////////////////
                            External functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Mints an NFT according to the provided mint request. Always mints 1 NFT.
    function mintWithSignature(MintRequest calldata _req, bytes calldata _signature)
        external
        payable
        nonReentrant
        returns (address signer)
    {
        signer = _processRequest(_req, _signature);
        address receiver = _req.to;
        uint256 tokenIdMinted = _mintTo(receiver, _req.uri);

        // Set royalties, if applicable.
        if (_req.royaltyRecipient != address(0) && _req.royaltyBps != 0) {
            _setupRoyaltyInfoForToken(tokenIdMinted, _req.royaltyRecipient, _req.royaltyBps);
        }

        _collectPrice(_req.primarySaleRecipient, _req.quantity, _req.currency, _req.pricePerToken);

        emit TokensMintedWithSignature(signer, receiver, tokenIdMinted, _req);
    }

    /// @dev Lets an account with MINTER_ROLE mint an NFT. Always mints 1 NFT.
    function mintTo(address _to, string calldata _uri) external onlyRole(MINTER_ROLE) returns (uint256 tokenIdMinted) {
        tokenIdMinted = _mintTo(_to, _uri);
        emit TokensMinted(_to, tokenIdMinted, _uri);
    }

    /// @dev Burns `tokenId`. See {ERC721-_burn}.
    function burn(uint256 tokenId) external virtual {
        // note: ERC721AUpgradeable's `_burn(uint256,bool)` internally checks for token approvals.
        _burn(tokenId, true);
    }

    /// @dev Burns `tokenId`. See {ERC721-_burn}.
    function burnAsAdmin(uint256 tokenId) external virtual onlyRole(METADATA_ROLE) {
        _burn(tokenId);
    }

    /*///////////////////////////////////////////////////////////////
                        Operator filter overrides
    //////////////////////////////////////////////////////////////*/

    /// @dev See {ERC721-setApprovalForAll}.
    function setApprovalForAll(address operator, bool approved) public override onlyAllowedOperatorApproval(operator) {
        super.setApprovalForAll(operator, approved);
    }

    /// @dev See {ERC721-approve}.
    function approve(address operator, uint256 tokenId) public override onlyAllowedOperatorApproval(operator) {
        super.approve(operator, tokenId);
    }

    /// @dev See {ERC721-_transferFrom}.
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override(ERC721AUpgradeable) onlyAllowedOperator(from) {
        super.transferFrom(from, to, tokenId);
    }

    /// @dev See {ERC721-_safeTransferFrom}.
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override(ERC721AUpgradeable) onlyAllowedOperator(from) {
        super.safeTransferFrom(from, to, tokenId);
    }

    /// @dev See {ERC721-_safeTransferFrom}.
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) public override(ERC721AUpgradeable) onlyAllowedOperator(from) {
        super.safeTransferFrom(from, to, tokenId, data);
    }

    /*///////////////////////////////////////////////////////////////
                        Miscellaneous
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns the total amount of tokens minted in the contract.
     */
    function totalMinted() external view returns (uint256) {
        unchecked {
            return _currentIndex - _startTokenId();
        }
    }

    /// @dev The tokenId of the next NFT that will be minted / lazy minted.
    function nextTokenIdToMint() external view returns (uint256) {
        return _currentIndex;
    }

    /*///////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Collects and distributes the primary sale value of NFTs being claimed.
    function _collectPrice(
        address _primarySaleRecipient,
        uint256 _quantityToClaim,
        address _currency,
        uint256 _pricePerToken
    ) internal {
        if (_pricePerToken == 0) {
            return;
        }

        (address platformFeeRecipient, uint16 platformFeeBps) = getPlatformFeeInfo();

        address saleRecipient = _primarySaleRecipient == address(0) ? primarySaleRecipient() : _primarySaleRecipient;

        uint256 totalPrice = _quantityToClaim * _pricePerToken;
        uint256 platformFees = (totalPrice * platformFeeBps) / MAX_BPS;

        if (_currency == CurrencyTransferLib.NATIVE_TOKEN) {
            require(msg.value == totalPrice, "!Price");
        } else {
            require(msg.value == 0, "!Value");
        }

        CurrencyTransferLib.transferCurrency(_currency, _msgSender(), platformFeeRecipient, platformFees);
        CurrencyTransferLib.transferCurrency(_currency, _msgSender(), saleRecipient, totalPrice - platformFees);
    }

    /// @dev Mints an NFT to `to`
    function _mintTo(address _to, string calldata _uri) internal returns (uint256 tokenIdToMint) {
        tokenIdToMint = _currentIndex;

        _setTokenURI(tokenIdToMint, _uri);
        _safeMint(_to, 1);
    }

    /// @dev See {ERC721-_beforeTokenTransfer}.
    function _beforeTokenTransfers(
        address from,
        address to,
        uint256 startTokenId,
        uint256 quantity
    ) internal virtual override {
        super._beforeTokenTransfers(from, to, startTokenId, quantity);

        // if transfer is restricted on the contract, we still want to allow burning and minting
        if (!hasRole(TRANSFER_ROLE, address(0)) && from != address(0) && to != address(0)) {
            if (!hasRole(TRANSFER_ROLE, from) && !hasRole(TRANSFER_ROLE, to)) {
                revert("!Transfer-Role");
            }
        }
    }

    /// @dev Checks whether platform fee info can be set in the given execution context.
    function _canSetPlatformFeeInfo() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// @dev Checks whether primary sale recipient can be set in the given execution context.
    function _canSetPrimarySaleRecipient() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// @dev Checks whether owner can be set in the given execution context.
    function _canSetOwner() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// @dev Checks whether royalty info can be set in the given execution context.
    function _canSetRoyaltyInfo() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// @dev Checks whether contract metadata can be set in the given execution context.
    function _canSetContractURI() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// @dev Returns whether a given address is authorized to sign mint requests.
    function _isAuthorizedSigner(address _signer) internal view override returns (bool) {
        return hasRole(MINTER_ROLE, _signer);
    }

    /// @dev Returns whether metadata can be set in the given execution context.
    function _canSetMetadata() internal view virtual override returns (bool) {
        return hasRole(METADATA_ROLE, _msgSender());
    }

    /// @dev Returns whether operator restriction can be set in the given execution context.
    function _canSetOperatorRestriction() internal virtual override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    function _msgSender()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address sender)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }
}
