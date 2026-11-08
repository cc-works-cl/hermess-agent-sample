import * as fs from 'fs';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as dlm from 'aws-cdk-lib/aws-dlm';
import { Construct } from 'constructs';

export class HermesStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // AMI は固定する。SSM の "current" を毎回解決すると、Canonical が新イメージを出したときに
    // インスタンスが置き換わり、~/.hermes と ~/.claude が消える。
    // 更新するときは scripts/lookup-ami.sh で ID を調べ、cdk.json の context "amiId" を書き換える。
    const amiId: string | undefined = this.node.tryGetContext('amiId');
    if (!amiId || !amiId.startsWith('ami-')) {
      throw new Error('context "amiId" が未設定です。scripts/lookup-ami.sh で取得して cdk.json に設定してください。');
    }
    // 実測でアイドル時のメモリ使用量は約 1GB（Hermes 関連プロセスは約 600MB）なので 2GB で足りる。
    // swap 4GB を UserData で作っている。足りなければ context で t3.medium に上げる。
    const instanceType: string = this.node.tryGetContext('instanceType') ?? 't3.small';
    const claudeCodeVersion: string = this.node.tryGetContext('claudeCodeVersion') ?? 'stable';

    // NAT Gateway を作らないために public subnet だけにする。inbound は SG で全閉。
    // AZ は明示する（maxAzs だと synth 時に AZ の lookup が走り、認証情報が必要になる）
    const vpc = new ec2.Vpc(this, 'Vpc', {
      availabilityZones: [this.node.tryGetContext('availabilityZone') ?? `${this.region}a`],
      natGateways: 0,
      subnetConfiguration: [{ name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 }],
    });

    const sg = new ec2.SecurityGroup(this, 'InstanceSg', {
      vpc,
      description: 'Hermes Agent: no inbound, egress only',
      allowAllOutbound: true,
    });

    // SSM セッションログの出力先。アカウント全体の Session Manager 設定で指定する（README 参照）。
    const sessionLogGroup = new logs.LogGroup(this, 'SessionLogGroup', {
      logGroupName: '/hermes/ssm-sessions',
      retention: logs.RetentionDays.THREE_MONTHS,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    const role = new iam.Role(this, 'InstanceRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore')],
    });
    role.addToPolicy(
      new iam.PolicyStatement({
        actions: ['logs:CreateLogStream', 'logs:PutLogEvents', 'logs:DescribeLogStreams'],
        resources: [sessionLogGroup.logGroupArn, `${sessionLogGroup.logGroupArn}:*`],
      }),
    );
    role.addToPolicy(
      new iam.PolicyStatement({ actions: ['logs:DescribeLogGroups'], resources: ['*'] }),
    );

    const userDataScript = fs
      .readFileSync(path.join(__dirname, '..', 'assets', 'user-data.sh'), 'utf8')
      .replace('__CLAUDE_CODE_VERSION__', claudeCodeVersion);
    const userData = ec2.UserData.custom(userDataScript);

    const instance = new ec2.Instance(this, 'Instance', {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      securityGroup: sg,
      role,
      instanceType: new ec2.InstanceType(instanceType),
      machineImage: ec2.MachineImage.genericLinux({ [this.region]: amiId }),
      userData,
      userDataCausesReplacement: false,
      associatePublicIpAddress: true,
      httpTokens: ec2.HttpTokens.REQUIRED,
      httpPutResponseHopLimit: 1,
      disableApiTermination: true,
      ssmSessionPermissions: false,
      blockDevices: [
        {
          deviceName: '/dev/sda1',
          volume: ec2.BlockDeviceVolume.ebs(30, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            encrypted: true,
            deleteOnTermination: false,
          }),
        },
      ],
    });
    cdk.Tags.of(instance).add('Name', 'hermes-agent');
    cdk.Tags.of(instance).add('hermes:snapshot', 'daily');

    // ルートボリュームを毎日スナップショットし、7 世代残す。
    const dlmRole = new iam.Role(this, 'DlmRole', {
      assumedBy: new iam.ServicePrincipal('dlm.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSDataLifecycleManagerServiceRole'),
      ],
    });
    new dlm.CfnLifecyclePolicy(this, 'SnapshotPolicy', {
      description: 'Hermes Agent daily EBS snapshots',
      state: 'ENABLED',
      executionRoleArn: dlmRole.roleArn,
      policyDetails: {
        resourceTypes: ['INSTANCE'],
        targetTags: [{ key: 'hermes:snapshot', value: 'daily' }],
        schedules: [
          {
            name: 'daily',
            createRule: { interval: 24, intervalUnit: 'HOURS', times: ['18:00'] },
            retainRule: { count: 7 },
            copyTags: true,
          },
        ],
      },
    });

    new cdk.CfnOutput(this, 'InstanceId', { value: instance.instanceId });
    new cdk.CfnOutput(this, 'SessionLogGroupName', { value: sessionLogGroup.logGroupName });
  }
}
