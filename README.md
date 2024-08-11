# Architecture

## Overview
We should try our best to ensure the following
- Keep our solution platform and tool agnostic
- If not possiblle then the solution should have a clear path for migration
This will facilitate agility not only to the platform but eventually to the business as well

## Manifesto
- The entire project should follow the principles of **IaC** for the infrastructure. **Terraform** is a great choice for this as we can define the entire infra in terraform files written in HCL (**Pulumi** can also be used utilizing other languages and can utilize terraform providers)
- **Terraform state file** locking can be ensured by using Terraform Cloud as it provides other benefits such as envs etc, but S3 can also be used.
- All backups, restore, maintenance tasks including updates and post-provisioning configurations for all resources that are outside EKS should be handled by **Ansible**.
- The infrastructure itself should be on **AWS** (or any other cloud) as it becomes easy for cluster autoscaling and to address resilience and SPOF by utilizing services like RDS, load balancers, NAT gateways, Availability Zones, CDN, etc.
- **Databases** should be run by **RDS**, DynamoDB, or Aurora as it is a cost-effective way of maintaining a database reliably and at scale.
- All code should be stored in a **Git repository** and should follow the **GitHub workflow**.
- **Branch policies** should be placed to ensure the right code enters the right branch using codeowners, rulesets, etc.
- The repo structure should represent all the environments and corresponding namespaces, and clusters should be created in the clusters.
- Code should be built using **GitHub Actions** and deployed **(CI/CD)**:
    - Dev
    - QA
    - Prod
- Applications should be packaged using **Helm** or **Kustomize**.
- Follow the **GitOps** approach to define all configurations on Git, and the **ArgoCD** operator pulls changes.
- Initial setup can be bootstrapped using **App of Apps** method in ArgoCd where the root app defines all other apps to be deployed.

## Tools Used
- Cloud infra - AWS
- Orchestration  - Kubernetes EKS
- Networking - Cillium
- DNS - Cloudflare
- Apps Package - Helm (or Kustomize)
- Database - (RDS or other managed service)
- Version Control - Github
- CI/CD - Github Actions
- IaC - Terraform and Ansible
- GitOps Cotroller - ArgoCD
- Monitoring and logging - Prometheus, Grafana, Loki, Promtail
- Testing - terratest, testkube

# Deployments 
Deplyoments consists of first time and update and for infranstructure and applications

## Infra deployments
This section is to stand up and maintain the infrastructure itself

### Terraform
Terraform is a good way to keep infrastructure definiton source controlled. It can keep a persistant state of the infrastructure which can be then used to check and apply differences between the current state and the desired state. It also helps in managing dependency by having collections of resources grouped together

#### State File
The state file in terraform helps persist the current state of the infrastructure. Hence care must be taken to 
- preserve the state file - Secured shared storage is the best place to store state file, as it may contain sensitive information. Should not be stored in source control
- lock the state file - use database for state file locking like dynamodb
The easiest alternative is to use is terraform cloud for state file management

#### Networking
- Create VPC 
- Create private and public subnet for each AZ in the region. (Should also target different regions when considering SPOF)
- Reserve Elastic IP seperate from the cluster defeinition (module to create eks can automatically create EIP but will be lost if the cluster is destroyed.). Reservinng an IP as a different resource retains this IP if the eks cluster is destroyed. This can be configured in the eks module as external NAT IP option
- We need 1 EIP per AZ
- We create one private and one public subnet for each Availability zone we target (3) with a cidr range ensure no overlaps occur
- Cillium networking can be installed here, but will be installed in ansible to keep it seperate from cloud configs

> [Code Example for network](terraform/network.tf)

#### EKS and related
- Create EKS cluster with the eks resource in terraform
- Define node group (managed or self managed) and its values for the worker nodes
    - Min, Max and desired capacity
    - instance types
    - launch template and its configs including os type and disk size etc
- Ensure to wait for cluster to come up before moving on. We can do this using the wait_for_cluster_cmd
- Once we have the cluster ID we can use this information to create other resources
- In order to use spot instances we use spot handler resource for handling spot instance termination. This is because when a spot instance is marked for termination spot_handler can gracefully remove pods from the node
- Autoscaling policy resource can be applied here targetting scaling by average cpu utilization of the ASG

> [Code Example for eks cluster](terraform/eks.tf)

#### Ingress and related
- Get/Create DNS zones for the domain names to be used on Cloudflare
- Create SSL certificates provisioned by AWS ACM (one per domain or wildcard)
    - Perform validation for the domain by adding appropriate records
- Deploy ingress controller. This can be done using helm charts of the ingress controller. WE will use nginx ingress controller and add the cluster record to the load balancer
- This will create an ELB outside of the cluster

> [Code Example for ingress](terraform/ingress.tf)

### Ansible
- Install Networking - Install the Cillium help chart. All nodes should be tainted until cillium is installed and running. Cillium can also be installed using the cli or manually to ensure idempotency
> [Code Example for cillium](ansible/cillium.yaml)
- Create ansible roles for each of the respective functions
    - Install aditional packages on the nodes
    - Create networking policies needed outside of EKS
    - Add packages and policies required by Compliance and security
> [Code Example for packages](ansible/packages.yaml)
- Start bootstrap of argocd
> [Code Example for argocd](ansible/argocd/values.yaml)
- Create init App of Apps

## Apps
The apps to be deployed are segregated into system apps, platform apps and user apps
### Init App deployment
The Apps to be deployed will use the app of apps method to bootstrap all apps required by the cluster including networking, monitoring, dns, certificates and logging, and also argocd 

### Bootstrap apps
- First we apply helm for argocd with values for the git repo
- Next we deploy applicationsets for each of our application stacks that contain respective applications
- The applicationset template should loop through all the stacks and run the generator from the respective paths in the git repo
> [Code Example for bootstrap](ansible/root/templates/stack.yaml)

#### System Apps
Required system apps that are critical for functionong of the cluster (mostly deployed using helm)
- cert-manager: Uses letsencrypt to generate and auto renew certs. Can also use private CA for internal apps. Configured to connect to cloudflare to solve dns challange
> [Code Example for cert-manager](system/cert-manager/)

-  external-dns: Configured to connect to cloudflare api to create dns records for apps. Can give special annotation to exclude certain apps
> [Code Example for external-dns](system/external-dns/)

- cloudflared - Cloudflare agent to create tunnel
> [Code Example for cloudflare](system/cloudflared/)

- ingress-nginx: Ingress controller . Can also use HaProxy or AWS ALB
> [Code Example for ingress controller](system/ingress-nginx/)

- kured - kubereboot daemon for automated and safe reboots of nodes including automated cordon and drain
> [Code Example for kured](system/kured/)

- loki - include promtail to forward logs to loki PLG  (can also use elk)
> [Code Example for loki](system/loki/)

- kube-prometheus-stack: installs prometheus, grafana and alertmanager. Should be configured for notification delivery and scrape logs from loki
> [Code Example for monitoring](system/monitoring-system/)

- rook-ceph (bonus) - Can be used to configured ceph storage - Is highly scalable, but can prove to be expense when running on cloud infrastructure
> [Code Example for rook](system/rook-ceph/)


#### Platform apps
Applications that add functionality and features to the cluster and the appplication deployed within
- github-runner - workers for github actions CI. Can also be Just in time runners which can be event based triggers
- dex - OpenID provider
- kanidm - lightweight identity management (can use aws IAM or ACtive Directory)
- rennovate - update manager to create automated prs for charts and dependency (can also use dependabot)
#### User apps
- frontend
- microservices
> [Code Example for app](app/)

#### IAM
- Create role/rolebindings for the type of users and the verbs they can access
- Create service accounts for ansible operations on the cluster and any pipelines

### Environments, Repositories and directory structure
#### GitOps operator
One argocd is deployed for all non prod cluster and one for prod cluster to ensure isolation and security. One argocd can be installed in each namespace in the prod cluster to mitigate single point of failure

#### Repositories
- APP REPO - The application code lives in its own repository and consists of the application code and the build definitions. 
- It also contains CI definitions to build and push the images  
- GITOPS REPO - This repository contains all of the kubernetes reource definitions and the configurations per environment that are requrired to deploy the app into the cluster
- IAC REPO - This repo contains all the code for the Infrastructure itself. This does not include code related to an application, but IaC code for terraform, aws specific configs and ansible roles and playbooks

#### Environments
- The GitOps repo can contain multiple folders each representing an environment
- DRY principles should be used to define the configurations making use of kustomize to create patch and overlays to generate configs while having common resource definitions for all environemnts
- Lower environments liek dev,QA,UAT, Pre-Prod should reside in a different kubernetes cluster from prod

### Update APP or new change to version
#### Github Actions CI/CD
The Flow:
Code is checked in 
- Build new image using github actions
    - Multistage docker file -
        - First build artifacts
        - Second, use scratch image without login to copy built artifact
    - Push image to lower env or with appropriate tag
    - Make config file change if needed using Packaging (Helm or kustomize)
        - The config repo is commited with 
            - new image 
            - New configs
            - The directory structure separates environemnts and checkin should be done to lower environment
        - ArgoCd detects new changes to the application in the specific env and deploys from the env specific folder as configured during setup
    - Perform testing
        - Once tested the changes are copied to the higher env folder
        - ArgoCd detects changes and deploys in the higher environments 
            - Environments can be segregated by namespaces or by different clusters

> [Code Example for a typlical CI](github/ci.yml)
        
### Application Packaging  
#### Helm:
Advantages:
- Many 3rd part applications are present and can be easy run
Some disadvantages:
- ArgoCd does not detect changes made to the config map values.
Workaround (Or arguably the right way)
- For the pods to be restarted with new values of the config map taking effect change the name/version number of the config map which will be considered as a new deployment and the pods will restart

#### Kustomize
Advantages:
- Can directly use kubectl -k to run 
- Configmapgen is good when many configs need to be generated. Can be inside the kustomization.yaml and doesn’t need a different configmap.yaml
- Great for common labels and annotations:
    - For service discovery
    - For prom discovery
    - For ingress discovery
    - Cert-manager
- Great for segregation of environments using patch and overlays

# Logging, Monitoring & Alerting
## Monitoring
Dashboards for monitoring should be setup for the following  metrics 
- Control Plane metrics
- Network metrics
- Storage metrics
- Security metrics

### Some metrics to track
- CoreDNS metrics
    - Overall Request packets 
    - request by dns records
    - request by zone
    - udp requests
    - tcp requests
    - request duration
    - udp response
    - tcp response
    - cache size and hitrate
- etcd metrics
    - uptime
    - db size
    - memory
    - client traffic in/out
    - peer trafic in/out
    - total leader elections
    - peer roud trip time
- api server
    - uptime
    - work queues
    - latency
    - memory and cpu usage
- cluster
    - cpu usage per app
    - cpu quota per app/namespace including pods, workloads, requests and limits
    - memory usage per app/namespace including pods, workloads, requests and limits
    - network usage per app/namespace
    - Realtime and average Bandwith per app/namespace TX/RX
    - Packet rate Tx/Rx
    - Dropped packet rates
    - Storage IO - IOPS and throughput
- node
    - cpu usage
    - memory
    - pods
    - network
- pods
    - cpu usage
    - memory
    - pods
    - network
    - quotas
- Persistant volumes
    - space usage
    - inode usage
- Security
    - Unauthorized access
    - Rate for access
    - policy violations
- Other metrics
    - scheduler
    - kubelet
    - controller manager

- Application metrics -
    Use opentelemetry for metric generation in the application
    - services
        - request latency
        - request rate
        - error rate
    - database
        - db query latency
        - db query rate
        - db connection count



## Alerting 
should be configured to send notification teams channel for the following
- High CPU usage
- High memory usage
- api server errors
- pod restarts

## Logging 
shoud be controlled by PLG stack (Promtail, loki, grafana)
- Common queries for logs
- Dashboards for application logs and server logs

# Testing
Testing should be implemented for code changes in the repositories. We can split the tests into infrastructure testing and application testing as we have different repos for each.
Tests are performed before merging to the main branch

## Infrastructure tests
Terraform based deployments can be tested using terratest. Tests are written in GO and are targetted to check resources created in AWS using terraform code. The test are deployed to aws or localstack to run tests and are destroyed when complete 
- PR to IaC repo deploys code to localstack, using localstack configs. This validates aws and terraform code
- Before merge terratest runs to check the following
    - Run against terraform directory
    - Retrys and errors during deploy
    - Fail if errors in init and apply
    - get ip of the instance/Get predictable value of resource
- Once validated the test environment is destroyed

Ansible scripts can use anisble-test to perform sanity tests, integration test and unit tests
and require right IAM permissions depending on the test

> [Code Example for terratest](tests/infra.go)

## Kubernetes Configs tests
Testing changes to the config repo. This can be achieved in tandum with terratest, testkube and postman
Integration -
- Deploy application with new version
- testkube uses postman collection to check if all applications have status 200

## Application tests
Unit tests should be developed for applications and CI should run these test
When image is pushed, the application is deployed using argocd on the test environment and testkube tests if the appication is reachable

--- 
> [!NOTE]
> A lot of the example code is taken from my personal kubernetes deployment, hence may have some additonal configuration than required for this assignment. I've tried to only add relevant snippets as much as possible unless they have dependencies to make sense out of it