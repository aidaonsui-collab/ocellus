# research/: sources

## Included in this folder (redistributable)

All of these files come from, or are derived from, an article published under the **Creative Commons Attribution 4.0 (CC BY 4.0)** license: https://creativecommons.org/licenses/by/4.0/

> Ryan K, Lu Z, Meinertzhagen IA (2016). *The CNS connectome of a tadpole larva of* Ciona intestinalis *(L.) highlights sidedness in the brain of a chordate sibling.* eLife 5:e16962. https://doi.org/10.7554/eLife.16962 · © 2016 Ryan et al.

| File | Origin | Notes |
|---|---|---|
| `elife-fig16-data1.xlsx` | Figure 16 source data 1: chemical synapse matrix. https://cdn.elifesciences.org/articles/16962/elife-16962-fig16-data1-v1.xlsx | Unmodified |
| `elife-fig16-data2.xlsx` | Figure 16 source data 2: putative gap-junction matrix. https://cdn.elifesciences.org/articles/16962/elife-16962-fig16-data2-v1.xlsx | Unmodified |
| `elife-fig1-data1.xlsx` | Figure 1 source data 1: cell-type key. https://cdn.elifesciences.org/articles/16962/elife-16962-fig1-data1-v1.xlsx | Unmodified |
| `ryan2016.xml` | Full-text JATS XML from Europe PMC. https://www.ebi.ac.uk/europepmc/webservices/rest/PMC5140270/fullTextXML | Unmodified |
| `ryan2016.txt` | Plain text extracted from `ryan2016.xml` (tags stripped) | Derived; used for searching |
| `graph.json` | Edge list built by `bench/scripts/build_graph.py` from the two Figure 16 matrices | **Derived (modified):** integer weights = depth ÷ 0.06 µm; labels not reconciled. Benchmark only |
| `matrix_stats.json` | Non-zero entry counts per matrix, from the same script | Derived |
| `reconcile.csv` | One row per source label, from `bench/scripts/build_connectome.py` | **Derived.** Alias decisions for Cor/coronet, BPN/90/92, and neck cells 165/166 |
| `signs.csv` | Excitatory/inhibitory sign per canonical cell | **Derived.** 28 inhibitory cells cited to Kourakis 2019, Bostwick 2020, or the Ryan cell key. Every other cell is an explicit default |
| `connectome.v1.json` | Canonical cells, edges, roles, and `data_hash` | **Derived.** This is the graph a frozen Connectome will store |
| `connectome.v1.bin` | Canonical binary whose blake2b256 is `data_hash` | Derived |
| `phase0_behavior.json` | Course and probe results from `bench/scripts/test_course.py` | Derived |

## Not included (listed for reference)

| Source | Why it's not in the repo | Link |
|---|---|---|
| Ryan et al. 2016, Figure 3 source data 1 (`elife-16962-fig3-data1.xlsx`, summary of all neurons) | CC BY, but a 2.8 MB binary that nothing in this repo uses yet. Download it if needed. | https://cdn.elifesciences.org/articles/16962/elife-16962-fig3-data1-v1.xlsx |
| PMC web page for Ryan et al. 2016 | Our saved copy was NCBI site markup, not article content. The XML above covers the article. | https://pmc.ncbi.nlm.nih.gov/articles/PMC5140270/ |
| Kourakis MJ et al. (2019). *Parallel visual circuitry in a basal chordate.* eLife 8:e44753 | Cited for neurotransmitter identities. CC BY, but not downloaded. | https://pmc.ncbi.nlm.nih.gov/articles/PMC6499539/ |
| Bostwick M et al. (2020). *Antagonistic inhibitory circuits integrate visual and gravitactic behaviors.* Curr Biol 30(4):600–609 | Journal copyright (Elsevier); the PMC copy is an author manuscript. Not redistributable here. | https://pmc.ncbi.nlm.nih.gov/articles/PMC7066595/ · https://doi.org/10.1016/j.cub.2019.12.017 |
| Hotta K, Dauga D, Manni L (2020). *The ontology of the anatomy and development of the solitary ascidian Ciona.* Sci Rep 10:17916 | Cited for larval timing. CC BY, but not downloaded. | https://www.nature.com/articles/s41598-020-73544-9 |
| Harada Y et al. (2008). *Mechanism of self-sterility in a hermaphroditic chordate.* Science 320:548–550 | Paywalled | https://doi.org/10.1126/science.1152488 |
| Sawada H et al. (2020). *Three multi-allelic gene pairs are responsible for self-sterility in the ascidian Ciona intestinalis.* Sci Rep 10:2514 | Cited only, not downloaded | https://doi.org/10.1038/s41598-020-59147-4 |
| Verasztó C et al. (2025). *Whole-body connectome of a segmented annelid larva.* eLife 13:RP97964 | Phase-5 candidate. CC BY, not downloaded. | https://pmc.ncbi.nlm.nih.gov/articles/PMC12387772/ |
| Winding M et al. (2023). *The connectome of an insect brain.* Science 379:eadd9330 | Paywalled. Check the data license before any use. | https://doi.org/10.1126/science.add9330 |
| Sui protocol and gas sources (protocol config, `gas_model/tables.rs`, Sui docs) | Linked, not vendored | See DESIGN.md §14 |
