locals {
  node_groups = {
    eks_nodes = {
      desired_capacity = var.autoscaling_minimum_size_by_az * length(data.aws_availability_zones.available_azs.zone_ids)
      min_capacity     = var.autoscaling_minimum_size_by_az * length(data.aws_availability_zones.available_azs.zone_ids)
      max_capacity     = var.autoscaling_maximum_size_by_az * length(data.aws_availability_zones.available_azs.zone_ids)

      instance_type = "t2.small"
      key_name      = var.key_name

      additional_tags = {
        Name = "${var.cluster_name}-eks-nodes"
      }

      launch_template = {
        id      = aws_launch_template.eks_nodes.id
        version = "$Latest"
      }

      scaling_config = {
        desired_size = var.autoscaling_minimum_size_by_az * length(data.aws_availability_zones.available_azs.zone_ids)
        max_size     = var.autoscaling_maximum_size_by_az * length(data.aws_availability_zones.available_azs.zone_ids)
        min_size     = var.autoscaling_minimum_size_by_az * length(data.aws_availability_zones.available_azs.zone_ids)
      }

      capacity_type = "ON_DEMAND"
    }
  }
}

# create EKS cluster
module "eks-cluster" {
  source           = "terraform-aws-modules/eks/aws"
  version          = "18.0.0"  # Update to the latest version
  cluster_name     = var.cluster_name
  cluster_version  = "1.19"
  write_kubeconfig = false
  wait_for_cluster_cmd = "until curl -k -s $ENDPOINT/healthz >/dev/null; do sleep 4; done"

  subnets = module.vpc.private_subnets
  vpc_id  = module.vpc.vpc_id

  node_groups = local.node_groups
}

resource "aws_launch_template" "eks_nodes" {
  name_prefix   = "${var.cluster_name}-eks-nodes"
  image_id      = var.ami_id
  instance_type = "t2.small"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 10
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.cluster_name}-eks-nodes"
    }
  }
}