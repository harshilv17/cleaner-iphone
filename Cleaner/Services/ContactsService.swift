import Contacts
import SwiftUI

struct ContactCluster: Identifiable, Sendable {
    let id: String
    let name: String
    /// Identifiers of every raw contact in the cluster, primary first.
    let ids: [String]
    let detail: String

    var extras: Int { max(0, ids.count - 1) }
}

@MainActor
@Observable
final class ContactsService {
    enum Access: Equatable { case unknown, denied, limited, full

        var canScan: Bool { self == .limited || self == .full }
    }

    private(set) var access: Access = .unknown
    private(set) var clusters: [ContactCluster] = []
    private(set) var scanning = false
    private(set) var lastError: String?

    private let store = CNContactStore()

    func refreshAccess() {
        access = Self.map(CNContactStore.authorizationStatus(for: .contacts))
    }

    func requestAccess() async {
        _ = try? await store.requestAccess(for: .contacts)
        refreshAccess()
    }

    private static func map(_ s: CNAuthorizationStatus) -> Access {
        switch s {
        case .authorized: .full
        case .limited: .limited
        case .denied, .restricted: .denied
        default: .unknown
        }
    }

    private static let keys: [CNKeyDescriptor] = [
        CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey,
        CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
    ].map { $0 as CNKeyDescriptor }

    func scan() async {
        guard access.canScan, !scanning else { return }
        scanning = true
        defer { scanning = false }

        let request = CNContactFetchRequest(keysToFetch: Self.keys)
        // Critical: the default unifies linked contacts, and deleting a unified
        // contact takes every linked record with it. Duplicate-finding has to work
        // on the raw records.
        request.unifyResults = false
        request.sortOrder = .givenName

        var contacts: [CNContact] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in contacts.append(contact) }
        } catch {
            lastError = error.localizedDescription
            return
        }
        clusters = Self.cluster(contacts)
    }

    // MARK: - Clustering

    static func normalizedName(_ c: CNContact) -> String {
        "\(c.givenName) \(c.familyName)"
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    /// Last 9 digits: enough to make +91 98765 43210, 098765 43210 and 9876543210
    /// land on the same key without colliding across real numbers.
    static func normalizedPhone(_ value: String) -> String? {
        let digits = value.filter(\.isNumber)
        guard digits.count >= 9 else { return nil }
        return String(digits.suffix(9))
    }

    static func cluster(_ contacts: [CNContact]) -> [ContactCluster] {
        var union = UnionFind(count: contacts.count)
        var byKey = [String: Int]()

        for (index, contact) in contacts.enumerated() {
            var keys: [String] = []
            let name = normalizedName(contact)
            if !name.isEmpty { keys.append("n:\(name)") }
            for phone in contact.phoneNumbers {
                if let p = normalizedPhone(phone.value.stringValue) { keys.append("p:\(p)") }
            }
            for email in contact.emailAddresses {
                let e = (email.value as String).lowercased()
                if !e.isEmpty { keys.append("e:\(e)") }
            }
            for key in keys {
                if let seen = byKey[key] { union.union(seen, index) } else { byKey[key] = index }
            }
        }

        var buckets = [Int: [CNContact]]()
        for (index, contact) in contacts.enumerated() {
            buckets[union.find(index), default: []].append(contact)
        }

        return buckets.values.filter { $0.count > 1 }.map { members in
            let primary = members.max { a, b in
                (a.phoneNumbers.count + a.emailAddresses.count)
                    < (b.phoneNumbers.count + b.emailAddresses.count)
            } ?? members[0]
            let name = [primary.givenName, primary.familyName]
                .filter { !$0.isEmpty }.joined(separator: " ")
            let phones = Set(members.flatMap { $0.phoneNumbers.map(\.value.stringValue) })
            return ContactCluster(
                id: primary.identifier,
                name: name.isEmpty ? (primary.organizationName.isEmpty ? "No name" : primary.organizationName) : name,
                ids: [primary.identifier] + members.filter { $0.identifier != primary.identifier }.map(\.identifier),
                detail: phones.sorted().joined(separator: " · ")
            )
        }
        .sorted { $0.extras > $1.extras }
    }

    // MARK: - Merging

    /// There is no public "merge contacts" API, so this does it by hand: union the
    /// labelled values onto the primary record, save it, then delete the others.
    /// Contacts in read-only containers (Exchange, some Google accounts) refuse
    /// deletion, so failures are reported per cluster rather than aborting the lot.
    @discardableResult
    func merge(_ cluster: ContactCluster) async -> Bool {
        let request = CNContactFetchRequest(keysToFetch: Self.keys)
        request.unifyResults = false
        var members: [CNContact] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                if cluster.ids.contains(contact.identifier) { members.append(contact) }
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
        guard let primary = members.first(where: { $0.identifier == cluster.id }),
              let merged = primary.mutableCopy() as? CNMutableContact
        else { return false }

        var phones = merged.phoneNumbers
        var emails = merged.emailAddresses
        for member in members where member.identifier != primary.identifier {
            for phone in member.phoneNumbers
            where !phones.contains(where: {
                Self.normalizedPhone($0.value.stringValue) == Self.normalizedPhone(phone.value.stringValue)
            }) {
                phones.append(phone)
            }
            for email in member.emailAddresses
            where !emails.contains(where: {
                ($0.value as String).lowercased() == (email.value as String).lowercased()
            }) {
                emails.append(email)
            }
        }
        merged.phoneNumbers = phones
        merged.emailAddresses = emails

        let save = CNSaveRequest()
        save.update(merged)
        for member in members where member.identifier != primary.identifier {
            if let copy = member.mutableCopy() as? CNMutableContact { save.delete(copy) }
        }
        do {
            try store.execute(save)
        } catch {
            lastError = error.localizedDescription
            return false
        }
        clusters.removeAll { $0.id == cluster.id }
        return true
    }
}
