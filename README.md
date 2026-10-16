# HZ Studio v1

Application Flutter Android + Windows de génération de fréquences réglables.

## Fonctionnalités V1
- Signal sinusoïdal, triangle, carré, fréquence 0,1 à 15000 Hz.
- Réglage de volume et préréglages, dont 432 et 440 Hz.
- Modulation à 7,83 Hz sur une porteuse à 220 Hz (pas un infrason réellement émis à 7,83 Hz).
- Lecture de segments WAV locaux en boucle.

## Limites
- La fonctionnalité 432/440 Hz sur une chanson existante n'est pas encore implémentée.
- Le contrôle global du son d'autres applications n'est pas fourni.
- La V1 génère des segments de quatre secondes, qui peuvent présenter une légère coupure à chaque boucle.
- Pas de validation matérielle Android/Windows avant build CI.

## CI
La GitHub Action crée les squelettes Flutter natifs puis compile l'APK et la distribution Windows. Pour Windows, télécharger l'archive entière de l'artefact (EXE + DLL dépendantes), pas seulement l'EXE.
