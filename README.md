# Transport Analyzer

ABAP report `ZTR_LANDSCAPE_STATUS` that runs in the development system and checks whether transport requests have been imported into the follow-on systems (e.g. QAS and PRD).

## Features
- Selection by transport number, owner (incl. task owners), last changed/released date (E070-AS4DATE) and request type (K/W/T by default)
- Filter: all / open only / released only
- Up to 3 target systems (default QAS, PRD)
- Per system: traffic light, return code and import date (read from the transport cofile, same data as the STMS import history)
- Analysis column: open, waiting for import, imported everywhere, import error, or wrong import sequence (e.g. in PRD but not QAS)
- Option to show only requests that are not fully imported
- Hotspot on the request number opens the request display (SE09)

## Installation
1. Create report `ZTR_LANDSCAPE_STATUS` in SE38 in the development system and paste `src/ztr_landscape_status.prog.abap`.
2. Create text symbols B01 "Transport selection", B02 "Request status", B03 "Target systems" and the selection texts.
3. Activate and run.

## Prerequisites
- The development system shares the transport directory (`/usr/sap/trans`) with the target systems.
- Runs on SAP NetWeaver / ABAP 7.50 and higher.
