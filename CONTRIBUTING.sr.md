# Doprinos

Kanon: [CONTRIBUTING.md](CONTRIBUTING.md) (engleski).

Hvala na patch-u. S.L.A.M je **alfa** macOS demon: mala izmena, zelen `swift test`, bez tajni.

## Okruženje

- macOS na Apple Silicon, pun Xcode (potreban je ugrađeni modul `Testing`)
- Swift 6.x (`// swift-tools-version:6.0` u `Package.swift`)
- Opciono: [Ollama](https://ollama.com) za žive provere (unit testovi stubuju mrežu)

```bash
swift build
swift test
```

Svaki PR mora ostaviti **`swift build` i `swift test` zelenim**. Jezički režim Swift 6, `-strict-concurrency=complete`: deljivo mutabilno stanje je u `actor`-u ili `Sendable`. Mreža — async `URLSession`. Bez busy-loop; blokirajući pozivi nisu na putu demona (izuzetak je pokretanje procesa).

Budžet mirovanja je deo specifikacije (RAM ≤ 100 MB, CPU ≲ 1%). Izmene mreže, SQLite ili `Process` ne smeju tiho da ga raznesu.

## Na čemu raditi

- Bagovi i ispravnost peščanika / HITL
- Testovi za ponašanje koje menjate
- Dokumentacija na **engleskom, ruskom i srpskom** ako menjate korisnički README/SPEC

Molimo **nemojte**:

- Komitovati `.env`, tokene, Keychain dump, stvarne chat ID-jeve
- Dodavati drugu SPM zavisnost bez jakog razloga (spec dozvoljava samo GRDB)
- Širiti opseg upisa peščanika usput — limit `WORKING_DIR/tmp` je eksplicitni **alfa** default; treba posebna diskusija

## Pull request

1. Fork i grana od `main`.
2. Testovi.
3. `swift test`.
4. Šablon PR-a.
5. [Kodeks ponašanja](CODE_OF_CONDUCT.md).

Ranjivosti: [SECURITY.sr.md](SECURITY.sr.md), ne javni issue.

## Licenca

Doprinos se licencira pod [MIT](LICENSE), kao i projekat.
