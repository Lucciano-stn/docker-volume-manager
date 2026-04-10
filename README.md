# docker-volume-manager
Backup et restauration de volume docker

# Docker Volume Manager

Script Bash de gestion des volumes Docker permettant :

- la sauvegarde de volumes Docker
- la restauration d’archives dans un volume Docker
- le listing des sauvegardes locales
- le listing des sauvegardes distantes via SFTP
- la gestion de la rétention locale et distante
- le mode `hot backup` ou `stop/start` des conteneurs
- la suppression optionnelle des sauvegardes locales après transfert distant

---

## Arborescence du projet

```bash
/opt/docker/newbackups/
├── archive/                         # Archives locales .tar.gz
├── log/                             # Fichiers de logs
└── script/
    ├── docker-volume-manager.sh     # Script principal
    ├── .env                         # Configuration
    └── exclude.txt                  # Volumes exclus du mode --all
