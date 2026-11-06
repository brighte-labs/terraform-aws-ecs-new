# ECS app worker

Derived from the nine Terraform files in
[DNXLabs/terraform-aws-ecs-app-worker at `79b5b209aa7a51a0d7903f1fa9437a6afd4b0dc0`](https://github.com/DNXLabs/terraform-aws-ecs-app-worker/tree/79b5b209aa7a51a0d7903f1fa9437a6afd4b0dc0).
The upstream Apache 2.0 licence is identical to the repository's [LICENSE](../../LICENSE).
Modified upstream files carry a local modification notice.

The only behavioural change is the ECS service lifecycle:

```hcl
ignore_changes = [task_definition, desired_count]
```

Terraform seeds `desired_count` when creating a service, then ignores runtime count
changes in every environment, including manual changes. The deployment pipeline
owns task-definition updates. This module does not configure autoscaling; callers
manage scaling limits and policies separately.

Resource names, indexing, [inputs and defaults](_variables.tf), and
[outputs](_outputs.tf) are preserved, including unused compatibility inputs.
Existing callers can preserve resource addresses by keeping their module label,
`count` and inputs when changing the source to this submodule.

Pin consumer sources to a reviewed full commit SHA:
`git::https://github.com/brighte-labs/terraform-aws-ecs-new.git//modules/ecs-app-worker?ref=<full-commit-sha>`.
For upgrades, compare against the upstream pin above and review any additional
behaviour or interface changes separately.

CI validates this submodule in isolation with Terraform 1.6.1 and AWS provider
6.31.0. The provider pin exists only in the temporary validation harness. The
inherited `data.aws_region.current.name` deprecation warning is retained; changing
that expression is outside this lifecycle fix.
