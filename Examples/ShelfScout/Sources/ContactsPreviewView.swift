import Contacts
import ContactsUI
import SwiftUI
import UIKit
import VLMKit

/// SwiftUI wrapper for `CNContactViewController(forNewContact:)` — Apple's
/// standard "preview a contact before adding it" UI. We hand it a pre-populated
/// `CNMutableContact` built from the VLM's `BusinessCardData`; the user can
/// inspect/edit each field and tap **Done** (which writes to Contacts via
/// `CNContactStore`, requiring the `NSContactsUsageDescription` entitlement)
/// or **Cancel**. Either way, the delegate fires and we dismiss the sheet.
struct ContactsPreviewView: UIViewControllerRepresentable {
    let data: BusinessCardData
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let contact = Self.makeContact(from: data)
        let cnVC = CNContactViewController(forNewContact: contact)
        cnVC.delegate = context.coordinator
        cnVC.allowsEditing = true
        return UINavigationController(rootViewController: cnVC)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        private let parent: ContactsPreviewView
        init(_ parent: ContactsPreviewView) { self.parent = parent }

        func contactViewController(
            _ viewController: CNContactViewController,
            didCompleteWith contact: CNContact?
        ) {
            parent.onDismiss()
        }
    }

    /// Map the VLM-extracted struct onto `CNMutableContact`. The mapping is
    /// best-effort: missing fields are simply omitted; non-standard phone-kind
    /// labels (e.g. "Atelier") fall through to `CNLabelOther` so they're still
    /// preserved as a contact entry rather than dropped.
    private static func makeContact(from data: BusinessCardData) -> CNMutableContact {
        let contact = CNMutableContact()
        if let given = data.givenName { contact.givenName = given }
        if let family = data.familyName { contact.familyName = family }
        // No split → preserve the printed full name in `givenName` so the user
        // can split it themselves in the preview editor.
        if data.givenName == nil, data.familyName == nil, let full = data.fullName {
            contact.givenName = full
        }
        if let phonetic = data.phoneticName {
            // Phonetic guides vary: sometimes just the family, sometimes
            // full. Stash on phoneticGivenName so search-by-pronunciation
            // works in Contacts; the user can move it in the editor if needed.
            contact.phoneticGivenName = phonetic
        }
        if let company = data.company { contact.organizationName = company }
        if let department = data.department { contact.departmentName = department }
        if let title = data.title { contact.jobTitle = title }

        contact.phoneNumbers = data.phones.map { phone in
            CNLabeledValue(
                label: cnPhoneLabel(for: phone.kind),
                value: CNPhoneNumber(stringValue: phone.number)
            )
        }
        contact.emailAddresses = data.emails.map {
            CNLabeledValue(label: CNLabelWork, value: $0 as NSString)
        }
        contact.urlAddresses = data.urls.map {
            CNLabeledValue(label: CNLabelWork, value: $0 as NSString)
        }
        if let address = data.address {
            // We don't try to parse the postal address into structured fields
            // (street/city/state/zip vary too much by locale); the whole printed
            // string lives in `street` so the user sees it in one place.
            let postal = CNMutablePostalAddress()
            postal.street = address
            contact.postalAddresses = [
                CNLabeledValue(label: CNLabelWork, value: postal)
            ]
        }
        contact.socialProfiles = data.socials.map { social in
            CNLabeledValue(
                label: social.platform,
                value: CNSocialProfile(
                    urlString: nil,
                    username: social.handle,
                    userIdentifier: nil,
                    service: social.platform
                )
            )
        }
        return contact
    }

    /// Snap our normalized phone-kind label to one of `CNLabel*` constants.
    /// Unknown kinds (including non-English labels that survived the recipe's
    /// normalization) fall through to `CNLabelOther` rather than being silently
    /// dropped.
    private static func cnPhoneLabel(for kind: String?) -> String {
        switch kind?.lowercased() {
        case "mobile": CNLabelPhoneNumberMobile
        case "office": CNLabelWork
        case "home": CNLabelHome
        case "fax": CNLabelPhoneNumberWorkFax
        case "main": CNLabelPhoneNumberMain
        default: CNLabelOther
        }
    }
}
