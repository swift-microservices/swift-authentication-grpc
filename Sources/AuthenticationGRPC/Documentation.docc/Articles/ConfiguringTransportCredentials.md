# Configuring transport credentials

Use scoped configuration readers to select certificate files while keeping deployment defaults in the application.

## Choose providers in the executable

Swift Configuration separates the sources of configuration from the types that read it. The
application creates the provider hierarchy, with environment overrides first:

```swift
import Configuration

let config = ConfigReader(providers: [
    EnvironmentVariablesProvider(),
    InMemoryProvider.applicationDefaults,
])
```

The application supplies its mounted file layout in an executable-local extension:

```swift
extension InMemoryProvider {
    static var applicationDefaults: Self {
        .init(values: [
            "tls.certificatePath": "/run/tls/cert.pem",
            "tls.privateKeyPath": "/run/tls/key.pem",
            "tls.trustRootsPath": "/run/tls/ca.pem",
            "temporal.tls.certificatePath": "/run/temporal-tls/cert.pem",
            "temporal.tls.privateKeyPath": "/run/temporal-tls/key.pem",
            "temporal.tls.trustRootsPath": "/run/temporal-tls/ca.pem",
        ])
    }
}
```

Include only the scopes the application uses. Temporal credentials are independent from service
credentials. Overriding `TLS_CERTIFICATE_PATH` does not change `TEMPORAL_TLS_CERTIFICATE_PATH`.

## Extend a type that has no native reader

Check the pinned library for native Swift Configuration support first. For a type that lacks it,
add a focused `Type+ConfigReader.swift` in the executable. Read relative keys and delegate to its
existing initializer:

```swift
import NIOCertificateReloading

extension TimedCertificateReloader.Configuration {
    init(config: ConfigReader) throws {
        self.init(
            refreshInterval: config.int(
                forKey: "refreshIntervalSeconds",
                as: Duration.self,
                default: .seconds(60)
            ),
            certificateSource: .init(
                location: .file(path: try config.requiredString(forKey: "certificatePath")),
                format: .pem
            ),
            privateKeySource: .init(
                location: .file(path: try config.requiredString(forKey: "privateKeyPath")),
                format: .pem
            )
        )
    }
}
```

Required accessors read from the entire provider hierarchy, including application defaults.
The initializer therefore needs only a scoped reader, not a directory or fallback path:

```swift
var reloaderConfig = try TimedCertificateReloader.Configuration(config: config.scoped(to: "tls"))
reloaderConfig.logger = logger
```

Use the same initializer with `config.scoped(to: "temporal.tls")` for a separate Temporal reloader.
Set lifecycle callbacks in the root, prime each reloader, and run it with its transports as shown
in <doc:MutualTLSAndCertificateRenewal>.

Transport-security adapters follow the same pattern: read `trustRootsPath` from the supplied
scope and take the existing reloader as a runtime dependency. Application paths belong in the
default provider; ordinary library tuning defaults can remain in the adapter.

## Keep configuration predictable

Application-owned numeric duration keys include their units. `tls.refreshIntervalSeconds`
becomes `TLS_REFRESH_INTERVAL_SECONDS`; the value is read as `Duration` in Swift. Preserve the
names and units of native library readers, including any internal subscopes.

Keep required-value checks and necessary validation in readers or the underlying library,
not in `Serve` or `Run`. Defaulted reads can fall back when conversion fails; choose throwing
accessors when that behavior would hide a configuration error. Mark actual secret values as
secret, and configure key material by path rather than embedding it in configuration.

For libraries adding native support, expose a convenience reader over relative keys and keep
provider selection, deployment defaults, and logging bootstrap with the application. See
[Configuring applications](https://swiftpackageindex.com/apple/swift-configuration/1.2.1/documentation/configuration/configuring-applications)
and [Configuring libraries](https://swiftpackageindex.com/apple/swift-configuration/1.2.1/documentation/configuration/configuring-libraries).
