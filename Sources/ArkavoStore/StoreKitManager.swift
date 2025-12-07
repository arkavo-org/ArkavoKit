import Foundation
import StoreKit

/// Manages StoreKit 2 product loading, purchases, and transaction verification
@MainActor
public final class StoreKitManager: ObservableObject {
    // MARK: - Published Properties

    @Published public private(set) var products: [Product] = []
    @Published public private(set) var purchasedProductIDs: Set<String> = []
    @Published public private(set) var isLoadingProducts = false
    @Published public private(set) var errorMessage: String?

    // MARK: - Private Properties

    private var transactionListener: Task<Void, Error>?

    // MARK: - Initialization

    public init() {
        transactionListener = listenForTransactions()
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Product Loading

    /// Load all encryption tier products from the App Store
    public func loadProducts() async {
        isLoadingProducts = true
        errorMessage = nil

        do {
            let storeProducts = try await Product.products(for: ProductIdentifier.allProducts)
            products = storeProducts.sorted { $0.price < $1.price }
            await updatePurchasedProducts()
        } catch {
            errorMessage = "Failed to load products: \(error.localizedDescription)"
        }

        isLoadingProducts = false
    }

    /// Get a specific product by ID
    public func product(for productID: String) -> Product? {
        products.first { $0.id == productID }
    }

    /// Get products for a specific encryption tier
    public func products(for tier: EntitlementTier) -> [Product] {
        let productIDs = ProductTierMapping.productIDs(for: tier)
        return products.filter { productIDs.contains($0.id) }
    }

    /// Monthly subscription products
    public var monthlyProducts: [Product] {
        products.filter { $0.id.contains("monthly") }
    }

    /// Yearly subscription products
    public var yearlyProducts: [Product] {
        products.filter { $0.id.contains("yearly") }
    }

    // MARK: - Purchases

    /// Purchase a product
    public func purchase(_ product: Product) async throws -> Transaction? {
        let result = try await product.purchase()

        switch result {
        case let .success(verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            await updatePurchasedProducts()
            return transaction

        case .userCancelled:
            return nil

        case .pending:
            return nil

        @unknown default:
            return nil
        }
    }

    /// Restore previous purchases
    public func restorePurchases() async throws {
        try await AppStore.sync()
        await updatePurchasedProducts()
    }

    // MARK: - Entitlement Checking

    /// Get the current encryption tier based on active subscriptions
    public func currentEncryptionTier() async -> EntitlementTier {
        var highestTier: EntitlementTier = .low

        for await result in Transaction.currentEntitlements {
            if case let .verified(transaction) = result {
                let tier = ProductTierMapping.tier(for: transaction.productID)
                if tier.encryptionLevel > highestTier.encryptionLevel {
                    highestTier = tier
                }
            }
        }

        return highestTier
    }

    /// Check if user has a specific encryption tier or higher
    public func hasAccess(to tier: EntitlementTier) async -> Bool {
        let currentTier = await currentEncryptionTier()
        return currentTier.encryptionLevel >= tier.encryptionLevel
    }

    // MARK: - Private Methods

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                if case let .verified(transaction) = result {
                    await transaction.finish()
                    await self.updatePurchasedProducts()
                }
            }
        }
    }

    private func updatePurchasedProducts() async {
        var purchased: Set<String> = []

        for await result in Transaction.currentEntitlements {
            if case let .verified(transaction) = result {
                purchased.insert(transaction.productID)
            }
        }

        purchasedProductIDs = purchased
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case let .unverified(_, error):
            throw StoreError.verificationFailed(error)
        case let .verified(safe):
            return safe
        }
    }
}

// MARK: - Errors

public enum StoreError: LocalizedError {
    case verificationFailed(Error)
    case purchaseFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .verificationFailed(error):
            "Transaction verification failed: \(error.localizedDescription)"
        case let .purchaseFailed(message):
            "Purchase failed: \(message)"
        }
    }
}
