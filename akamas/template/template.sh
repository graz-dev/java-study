#!/bin/bash
bash /work/code/java-study/akamas/scripts/patch_petclinic.sh \
  --cpu-request ${petclinic_container.cpu_request}m \
  --cpu-limit ${petclinic_container.cpu_limit}m \
  --memory-request ${petclinic_container.memory_request}Mi \
  --memory-limit ${petclinic_container.memory_limit}Mi \
  --jvm-opts "${petclinic_jvm.*}" \
  --hpa-cpu-target ${petclinic_hpa.targetCPUUtilizationPercentage}
