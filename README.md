# azure-function
### Azure function to start / stop automatically vm
### Azure function to start / stop automatically app gateway (Besoin finOps)
1. Lister l'ensembles des app gateway sur la suscription ayant un tags spécifique
2. Durant les jours ouvrés (weekday): Arréter les app gtw à 19H, et les démarer à 07H du matin
3. Durant les week-end(weekendday): Arréter les app gtw
4. Utiliser un script powershel, et automatiser l'execution avec azure function

### Azure policy pour rendre obligatoire certains tags sur les resource app gtw
1. Créer un azure policy custom pour rendre obligatoire un tags sur app gtw
2. Assigner le policy niveau subscription ou resource group

### Integration app diagnostic settings, azure event hub, elasticsearch
1. Pousser les logs des ressources azure vers elastic search pour un besoin finOps et un accès centraliser des logs
