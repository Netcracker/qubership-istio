## Deployment schemas
### Non-HA
*Supported*: yes
*Kubernetes*: yes
*VM*: NA  
### HA
*Supported*: yes
*Kubernetes*: yes
*VM*: NA
### DR 
*Supported*: no  
*Kubernetes*: no  
*VM*: NA 
## Installation
### Helm
*Supported*: yes
*Kubernetes*: yes
*VM*: NA  
*Fully automated*: yes 
### AppDeployer
*Supported*: yes
*Kubernetes*: yes
*VM*: NA  
*Fully automated*: yes
### Ansible
*Supported*: no  
*Kubernetes*: no
*VM*: NA  
*Fully automated*: no  
**Note**: Additional important information  
## Rolling Upgrade
### Helm
*Supported*: yes
*Kubernetes*: yes
*VM*: NA  
*Fully automated*: yes
*Downtime*: no
### AppDeployer 
*Supported*: yes
*Kubernetes*: yes
*VM*: NA
*Fully automated*: yes
*Downtime*: no
### Ansible
*Supported*: no  
*Kubernetes*: no
*VM*: NA  
*Fully automated*: no  
*Downtime*: NA
## Backup/Restore
### Full Backup
*Supported*: yes
*Snapshots*: yes 
*Downtime*: no
**Note**: All state is stored in kubernetes resources, no PVs - so it is enough to backup/restore kubernetes resources.
### Backup per scheme
*Supported*: NA  
*Snapshots*: NA  
*Downtime*: NA
### Incremental Backup
*Supported*: NA  
*Snapshots*: NA  
*Downtime*: NA
### Incremental Backup per scheme
*Supported*: NA  
*Snapshots*: NA  
*Downtime*: NA
### Full Restore
*Supported*: yes
*Snapshots*: yes
*Downtime*: no
### Restore per scheme
*Supported*: NA  
*Snapshots*: NA  
*Downtime*: NA
### Point in time recovery
*Supported*: NA  
*Snapshots*: NA  
*Downtime*: NA
### Point in time recovery per scheme
*Supported*: NA  
*Snapshots*: NA  
*Downtime*: NA 
## Storage
*Backups*: s3/nfs/NA  
*Data*: PV/Local/etc.  
## Encryption
### Data encryption
*Supported*: yes
**Note**: mTLS enabled by default.
### Protocol encryption
#### TLS
*Supported*: yes
#### mTLS
*Supported*: yes
## Managed services
### AWS
### GCP
### Azure