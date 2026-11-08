#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { HermesStack } from '../lib/hermes-stack';

const app = new cdk.App();

new HermesStack(app, 'HermesAgentStack', {
  env: {
    // account は指定しない（指定すると synth 時に AZ の lookup が走り、認証情報が必要になる）
    // CDK_DEFAULT_REGION は認証情報がないと us-east-1 になるため使わない
    region: app.node.tryGetContext('region') ?? 'ap-northeast-1',
  },
  description: 'Hermes Agent on EC2 (SSM only, no inbound)',
});
