# War room assets: sources and licences

Assets used by `quest/xr/room.gd`. Everything here is CC0 (public domain dedication), public domain, or CC BY 4.0
with the credit given below. Changes made for the Quest are listed per asset.

Generated files: `room.lmbake` and `room.exr` are the baked lightmap of the room (made by `quest/tools/bake-room.sh`
from the assets below). `*.import` are Godot import settings; `*.unwrap_cache` keep the lightmap UV unwrap of the models
the same on every machine, so the committed lightmap fits them. Both are needed and are committed.

## Textures (`textures/`)

| Files | Asset | Source | Author | Licence | Changes |
|---|---|---|---|---|---|
| `castle_wall_slates_*_2k.jpg` | Castle Wall Slates | https://polyhaven.com/a/castle_wall_slates | Rob Tuytel | CC0 | none (diffuse, normal GL, ARM, displacement) |
| `monastery_stone_floor_*_2k.jpg` | Monastery Stone Floor | https://polyhaven.com/a/monastery_stone_floor | Amal Kumar | CC0 | none |
| `dark_wooden_planks_*_2k.jpg` | Dark Wooden Planks | https://polyhaven.com/a/dark_wooden_planks | Amal Kumar | CC0 | none |
| `medieval_wood_*_2k.jpg` | Medieval Wood | https://polyhaven.com/a/medieval_wood | Rob Tuytel | CC0 | none |
| `quatrefoil_jacquard_fabric_grey_1k.jpg`, `quatrefoil_jacquard_fabric_nor_gl_1k.jpg` | Quatrefoil Jacquard Fabric | https://polyhaven.com/a/quatrefoil_jacquard_fabric | colormass, Rico Cilliers | CC0 | diffuse turned to grey, so the banners take the player colours |
| `Carpet015_1K-JPG_*.jpg` | Carpet 015 | https://ambientcg.com/view?id=Carpet015 | ambientCG (Lennart Demes) | CC0 (https://docs.ambientcg.com/license/) | none |

## Models

| Folder / files | Asset | Source | Author | Licence | Changes |
|---|---|---|---|---|---|
| `polyhaven/wooden_bookshelf_worn/` | Wooden Bookshelf Worn | https://polyhaven.com/a/wooden_bookshelf_worn | Ulan Cabanilla | CC0 | none |
| `polyhaven/kite_shield/` | Kite Shield | https://polyhaven.com/a/kite_shield | Ulan Cabanilla | CC0 | none |
| `polyhaven/Chandelier_02/` | Chandelier 02 | https://polyhaven.com/a/Chandelier_02 | Kirill Sannikov | CC0 | none |
| `polyhaven/large_castle_door/` | Large Castle Door | https://polyhaven.com/a/large_castle_door | Tina | CC0 | none |
| `polyhaven/wine_barrel_01/` | Wine Barrel 01 | https://polyhaven.com/a/wine_barrel_01 | James Ray Cock | CC0 | none |
| `polyhaven/wooden_axe/` | Wooden Axe | https://polyhaven.com/a/wooden_axe | Ulan Cabanilla | CC0 | none |
| `polyhaven/ornate_medieval_mace/` | Ornate Medieval Mace | https://polyhaven.com/a/ornate_medieval_mace | Ulan Cabanilla | CC0 | none |
| `kaykit/` (castles, towers, flags, `hexagons_medieval.png`, `LICENSE.txt`) | KayKit Medieval Hexagon Pack 1.0 | https://github.com/KayKit-Game-Assets/KayKit-Medieval-Hexagon-Pack-1.0 | Kay Lousberg (www.kaylousberg.com) | CC0 | none |

### Meshy AI models (`meshy/`): CC BY 4.0

3D models generated with Meshy AI (https://www.meshy.ai), CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/),
under the Meshy Terms of Use for the free plan (https://www.meshy.ai/terms-of-use, section 3.2). Credit: "Generated with
Meshy AI (meshy.ai), CC BY 4.0". They are AI-generated.

| Files | Meshy task (refine) | Changes |
|---|---|---|
| `war_table.*` | 01a1b32b-7c28-76bc-8ec8-8d09bc5550b4 | GLB split into glTF + .bin + JPEG, textures scaled 2048 to 1024 px, scaled to real size (top at 0.8 m), origin moved to the bottom |
| `lords_chair.*` | 01a1b329-db0d-777f-b9f8-de4c5db43ed0 | as above, 1.2 m tall |
| `wall_torch.*` | 01a1b32c-fe1d-7310-8b0d-1811e2e30f48 | as above, 0.6 m tall; the white flame on top removed (a shader flame replaces it) |
| `treasure_chest.*` | 01a1b32e-b981-7004-9d71-58c9e34935d4 | as above, 0.8 m wide |
| `weapon_rack.*` | 01a1b330-060c-73ba-8b12-63c16542de29 | as above, 1.8 m tall; a loose spear and a floating fragment (two mesh islands) removed |

## Paintings (`paintings/`): public domain

Photographs of two-dimensional public-domain works of art, from Wikimedia Commons, where they are marked public domain
(the painters died more than 100 years ago; faithful reproductions add no copyright, see
https://commons.wikimedia.org/wiki/Commons:When_to_use_the_PD-Art_tag). Downloaded as the 1280 px wide Commons thumbnails.

| File | Painting | Source | Status |
|---|---|---|---|
| `uccello_battle_of_san_romano.jpg` | Paolo Uccello, The Battle of San Romano (c. 1438), National Gallery, London | https://commons.wikimedia.org/wiki/File:San_Romano_Battle_(Paolo_Uccello,_London)_01.jpg | Public domain (Commons) |
| `bierstadt_among_the_sierra_nevada.jpg` | Albert Bierstadt, Among the Sierra Nevada, California (1868) | https://commons.wikimedia.org/wiki/File:Albert_Bierstadt_-_Among_the_Sierra_Nevada,_California_-_Google_Art_Project.jpg | Public domain (Commons) |
| `cole_the_savage_state.jpg` | Thomas Cole, The Course of Empire: The Savage State (1834) | https://commons.wikimedia.org/wiki/File:Cole_Thomas_The_Course_of_Empire_The_Savage_State_1836.jpg | Public domain (Commons) |

## Made in code (no files)

Room shell, fireplace, banners, books, frames, candles, logs, the flame, night-sky and light-shaft shaders, and the
particles are built in `room.gd`.
