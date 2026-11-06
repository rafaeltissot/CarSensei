# CarPlay — como desativar para a App Store

Todo o código do CarPlay está nesta pasta e atrás da flag de compilação `CARPLAY_ENABLED`.

Para publicar sem CarPlay:

1. `ios/CarSensei.xcodeproj` → target CarSensei → Build Settings → Swift Compiler - Custom Flags →
   remova `CARPLAY_ENABLED` de **Active Compilation Conditions** (Debug e Release).
2. `ios/Info.plist`: apague as chaves `CPTemplateApplicationSceneSessionRoleApplication` e
   `UIWindowSceneSessionRoleCarPlay` (e o `UIApplicationSceneManifest` inteiro, se ficar vazio).
3. `ios/CarSensei/CarSensei.entitlements`: apague `com.apple.developer.carplay-audio` e
   `com.apple.developer.carplay-video` (a Apple rejeita entitlement de CarPlay sem aprovação).
4. Opcional: apague os arquivos `CarPlayDashboard.swift` e `CarSenseiStore+CarPlay.swift` desta pasta.
   Mantenha `CarPlayRecurso.swift`: sem a flag ele só devolve "nada".
5. Textos do site (`docs/`) e do `README.md` que citam CarPlay.
