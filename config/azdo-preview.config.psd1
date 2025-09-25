@{
    OrganizationUrl        = 'https://dev.azure.com/wesleytrust'
    Project                = 'cloud-platform-public'
    SelfRef                = 'refs/heads/main'
    ExamplesBranch         = 'refs/heads/main'
    PipelineCommonRef      = 'refs/heads/main'
    PipelineDispatcherRef  = 'refs/heads/main'
    PreviewPipelineId      = 132
    PipelineIds            = @(132)
    PipelineDefinitions    = @(
        @{
            PipelineId     = 132
            Name           = 'Bicep Plus Tests'
            PipelinePath   = 'examples/consumer/bicep-plus-tests.pipeline.yml'
            ParameterSets  = @(
                @{
                    Name = 'defaults'
                    TemplateParameters = @{}
                },
                @{
                    Name = 'prod-review-disabled'
                    TemplateParameters = @{
                        doNotRunReviewStage = $true
                        skip_qa        = $false
                        skip_preprod   = $false
                        enableProduction = $true
                    }
                },
                @{
                    Name = 'bicep-tests-smoke-delay'
                    TemplateParameters = @{
                        bicepTestsDelayMinutes = 15
                        doNotRunSmoke              = $false
                        doNotRunRegression         = $true
                    }
                }
            )
        }
    )
}
