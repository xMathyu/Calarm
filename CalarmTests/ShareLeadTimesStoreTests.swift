//
//  ShareLeadTimesStoreTests.swift
//  CalarmTests
//

import Foundation
import Testing
@testable import Calarm

/// Locks in the rule that makes a recipient's own avisos survive the shared-DB
/// scan: the personal list wins over the owner's payload until it matches it again.
struct ShareLeadTimesStoreTests {

    /// A recipient who never touched the avisos follows the owner's list.
    @Test func untouchedShareFollowsOwner() {
        let id = UUID()
        defer { ShareLeadTimesStore.forget(id) }

        ShareLeadTimesStore.recordShared([.atStart], for: id)
        #expect(ShareLeadTimesStore.personal(for: id) == nil)
    }

    /// The reported bug: an aviso the recipient added must outlive the next scan.
    @Test func personalAvisoSurvivesOwnerPayload() {
        let id = UUID()
        defer { ShareLeadTimesStore.forget(id) }

        ShareLeadTimesStore.recordShared([.atStart], for: id)
        ShareLeadTimesStore.setPersonal([.atStart, .hour2], for: id)

        // A later scan re-records the owner's (unchanged) list.
        ShareLeadTimesStore.recordShared([.atStart], for: id)

        #expect(ShareLeadTimesStore.personal(for: id) == [.atStart, .hour2])
    }

    /// The owner changing their own avisos doesn't clobber the recipient's.
    @Test func ownerChangeKeepsPersonalAvisos() {
        let id = UUID()
        defer { ShareLeadTimesStore.forget(id) }

        ShareLeadTimesStore.recordShared([.atStart], for: id)
        ShareLeadTimesStore.setPersonal([.atStart, .hour2], for: id)
        ShareLeadTimesStore.recordShared([.atStart, .min10], for: id)

        #expect(ShareLeadTimesStore.personal(for: id) == [.atStart, .hour2])
    }

    /// Setting the avisos back to the owner's list drops the override, so the
    /// alarm follows the owner again.
    @Test func matchingOwnerClearsOverride() {
        let id = UUID()
        defer { ShareLeadTimesStore.forget(id) }

        ShareLeadTimesStore.recordShared([.atStart, .min10], for: id)
        ShareLeadTimesStore.setPersonal([.atStart, .hour2], for: id)
        #expect(ShareLeadTimesStore.personal(for: id) != nil)

        // Same set, different order — still "the owner's list".
        ShareLeadTimesStore.setPersonal([.min10, .atStart], for: id)
        #expect(ShareLeadTimesStore.personal(for: id) == nil)
    }

    /// Deleting the invitation forgets the personal avisos too.
    @Test func forgetDropsEverything() {
        let id = UUID()
        ShareLeadTimesStore.recordShared([.atStart], for: id)
        ShareLeadTimesStore.setPersonal([.hour2], for: id)

        ShareLeadTimesStore.forget(id)
        #expect(ShareLeadTimesStore.personal(for: id) == nil)
    }

    /// A share the owner deleted or unshared is pruned, so a re-share starts
    /// from the owner's avisos instead of resurrecting a stale override.
    @Test func pruneDropsAbsentShares() {
        let kept = UUID()
        let gone = UUID()
        defer { ShareLeadTimesStore.forget(kept); ShareLeadTimesStore.forget(gone) }

        ShareLeadTimesStore.recordShared([.atStart], for: kept)
        ShareLeadTimesStore.setPersonal([.hour2], for: kept)
        ShareLeadTimesStore.recordShared([.atStart], for: gone)
        ShareLeadTimesStore.setPersonal([.hour2], for: gone)

        ShareLeadTimesStore.prune(presentIDs: [kept])

        #expect(ShareLeadTimesStore.personal(for: kept) == [.hour2])
        #expect(ShareLeadTimesStore.personal(for: gone) == nil)
    }
}
