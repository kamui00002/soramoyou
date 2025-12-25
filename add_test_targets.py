#!/usr/bin/env python3
"""
Xcodeプロジェクトファイルにテストターゲットを追加するスクリプト
"""

import re
import sys

# UUID（事前に生成済み）
TEST_TARGET_UUID = "D65E897595FD46559102C241"
TEST_PRODUCT_UUID = "9E295B769DDC4DEDAEA4B422"
TEST_CONFIG_LIST_UUID = "D064B775833C4F35A3E852B2"
TEST_SOURCES_UUID = "218BEDD08B9744AEA5F739DE"
TEST_FRAMEWORKS_UUID = "C4476676F5AF4E39B23CCEB0"
TEST_RESOURCES_UUID = "561D4C6202C243E882823307"
TEST_DEPENDENCY_UUID = "6018FFB8ADA042908F7F3561"
TEST_DEBUG_CONFIG_UUID = "30D27324CFAB4333AA1F5852"
TEST_RELEASE_CONFIG_UUID = "94D843ECDA29482CB196640F"
TEST_GROUP_UUID = "E3DC2D138EA64B428ED35917"
TEST_SYNC_GROUP_UUID = "15100AD28C534F9C82F6D431"

UI_TEST_TARGET_UUID = "82858D45CB874FB9BF73607B"
UI_TEST_PRODUCT_UUID = "D75B7B7367A04B24A51DB57D"
UI_TEST_CONFIG_LIST_UUID = "5927E52BAAFD423682C7DFBF"
UI_TEST_SOURCES_UUID = "105BD88A4878414A926B8CCC"
UI_TEST_FRAMEWORKS_UUID = "A2FA2534D652402F81FF60E6"
UI_TEST_RESOURCES_UUID = "60999F5E201C4CD2B7E9BA9D"
UI_TEST_DEPENDENCY_UUID = "3D251E6A679B43888CFCAB37"
UI_TEST_DEBUG_CONFIG_UUID = "3C6313E5E9FF4C6E904BA9EC"
UI_TEST_RELEASE_CONFIG_UUID = "7BE628781A6F47989ED1E5BA"
UI_TEST_GROUP_UUID = "7F90913E791E4798AC8EBEEC"
UI_TEST_SYNC_GROUP_UUID = "C4C7346B3CA447068651AC19"

# メインターゲットのUUID（既存）
MAIN_TARGET_UUID = "E051C9D52EE497CA00CC78AB"
MAIN_APP_PRODUCT_UUID = "E051C9D62EE497CA00CC78AB"
PROJECT_UUID = "E051C9CE2EE497CA00CC78AB"
PRODUCTS_GROUP_UUID = "E051C9D72EE497CA00CC78AB"
ROOT_GROUP_UUID = "E051C9CD2EE497CA00CC78AB"
MAIN_SYNC_GROUP_UUID = "E051C9D82EE497CA00CC78AB"

# パッケージ依存関係のUUID（既存）
FIREBASE_AUTH_UUID = "E051CA482EE49ACB00CC78AB"
FIREBASE_FIRESTORE_UUID = "E051CA4C2EE49ACB00CC78AB"
FIREBASE_STORAGE_UUID = "E051CA4C2EE49ACB00CC78AB"  # Firestoreと同じパッケージ
FIREBASE_CRASHLYTICS_UUID = "E051CA4A2EE49ACB00CC78AB"
FIREBASE_ANALYTICS_UUID = "E051CA462EE49ACB00CC78AB"
KINGFISHER_UUID = "E051CA4F2EE49B0200CC78AB"
GOOGLE_MOBILE_ADS_UUID = "E051CA522EE49B3400CC78AB"

def add_test_targets(content):
    """テストターゲットを追加"""
    
    # 1. PBXFileReferenceセクションにテストプロダクトを追加
    file_ref_section = re.search(r'(/\* Begin PBXFileReference section \*/\n)(.*?)(/\* End PBXFileReference section \*/\n)', content, re.DOTALL)
    if file_ref_section:
        new_file_refs = f"""\t\t{MAIN_APP_PRODUCT_UUID} /* Soramoyou.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Soramoyou.app; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{TEST_PRODUCT_UUID} /* SoramoyouTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = SoramoyouTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{UI_TEST_PRODUCT_UUID} /* SoramoyouUITests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = SoramoyouUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};"""
        content = content.replace(file_ref_section.group(0), file_ref_section.group(1) + new_file_refs + "\n" + file_ref_section.group(3))
    
    # 2. PBXFileSystemSynchronizedRootGroupセクションにテストグループを追加
    sync_group_section = re.search(r'(/\* Begin PBXFileSystemSynchronizedRootGroup section \*/\n)(.*?)(/\* End PBXFileSystemSynchronizedRootGroup section \*/\n)', content, re.DOTALL)
    if sync_group_section:
        new_sync_groups = f"""\t\t{MAIN_SYNC_GROUP_UUID} /* Soramoyou */ = {{
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\tpath = Soramoyou;
\t\tsourceTree = "<group>";
\t\t}};
\t\t{TEST_SYNC_GROUP_UUID} /* SoramoyouTests */ = {{
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\tpath = SoramoyouTests;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{UI_TEST_SYNC_GROUP_UUID} /* SoramoyouUITests */ = {{
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\tpath = SoramoyouUITests;
\t\t\tsourceTree = "<group>";
\t\t}};"""
        content = content.replace(sync_group_section.group(0), sync_group_section.group(1) + new_sync_groups + "\n" + sync_group_section.group(3))
    
    # 3. PBXGroupセクションにテストグループを追加
    group_section = re.search(r'(/\* Begin PBXGroup section \*/\n)(.*?)(/\* End PBXGroup section \*/\n)', content, re.DOTALL)
    if group_section:
        # ルートグループにテストグループを追加
        root_group = re.search(rf'({ROOT_GROUP_UUID} = \{{[^}}]*children = \()(.*?)(\);.*?sourceTree = "<group>";)', content, re.DOTALL)
        if root_group:
            new_children = f"""{root_group.group(2)}
\t\t\t{TEST_GROUP_UUID} /* SoramoyouTests */,
\t\t\t{UI_TEST_GROUP_UUID} /* SoramoyouUITests */,"""
            content = content.replace(root_group.group(0), root_group.group(1) + new_children + "\n\t\t\t" + root_group.group(3))
        
        # Productsグループにテストプロダクトを追加
        products_group = re.search(rf'({PRODUCTS_GROUP_UUID} = \{{[^}}]*children = \()(.*?)(\);.*?name = Products;)', content, re.DOTALL)
        if products_group:
            new_products = f"""{products_group.group(2)}
\t\t\t{TEST_PRODUCT_UUID} /* SoramoyouTests.xctest */,
\t\t\t{UI_TEST_PRODUCT_UUID} /* SoramoyouUITests.xctest */,"""
            content = content.replace(products_group.group(0), products_group.group(1) + new_products + "\n\t\t\t" + products_group.group(3))
        
        # テストグループを追加
        new_groups = f"""
\t\t{TEST_GROUP_UUID} /* SoramoyouTests */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{TEST_SYNC_GROUP_UUID} /* SoramoyouTests */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{UI_TEST_GROUP_UUID} /* SoramoyouUITests */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{UI_TEST_SYNC_GROUP_UUID} /* SoramoyouUITests */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};"""
        content = content.replace(group_section.group(2), group_section.group(2) + new_groups)
    
    # 4. PBXSourcesBuildPhaseセクションにテストソースを追加
    sources_section = re.search(r'(/\* Begin PBXSourcesBuildPhase section \*/\n)(.*?)(/\* End PBXSourcesBuildPhase section \*/\n)', content, re.DOTALL)
    if sources_section:
        new_sources = f"""
\t\t{TEST_SOURCES_UUID} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{UI_TEST_SOURCES_UUID} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};"""
        content = content.replace(sources_section.group(2), sources_section.group(2) + new_sources)
    
    # 5. PBXFrameworksBuildPhaseセクションにテストフレームワークを追加
    frameworks_section = re.search(r'(/\* Begin PBXFrameworksBuildPhase section \*/\n)(.*?)(/\* End PBXFrameworksBuildPhase section \*/\n)', content, re.DOTALL)
    if frameworks_section:
        new_frameworks = f"""
\t\t{TEST_FRAMEWORKS_UUID} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{UI_TEST_FRAMEWORKS_UUID} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};"""
        content = content.replace(frameworks_section.group(2), frameworks_section.group(2) + new_frameworks)
    
    # 6. PBXResourcesBuildPhaseセクションにテストリソースを追加
    resources_section = re.search(r'(/\* Begin PBXResourcesBuildPhase section \*/\n)(.*?)(/\* End PBXResourcesBuildPhase section \*/\n)', content, re.DOTALL)
    if resources_section:
        new_resources = f"""
\t\t{TEST_RESOURCES_UUID} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{UI_TEST_RESOURCES_UUID} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};"""
        content = content.replace(resources_section.group(2), resources_section.group(2) + new_resources)
    
    # 7. PBXNativeTargetセクションにテストターゲットを追加
    target_section = re.search(r'(/\* Begin PBXNativeTarget section \*/\n)(.*?)(/\* End PBXNativeTarget section \*/\n)', content, re.DOTALL)
    if target_section:
        new_targets = f"""
\t\t{TEST_TARGET_UUID} /* SoramoyouTests */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {TEST_CONFIG_LIST_UUID} /* Build configuration list for PBXNativeTarget "SoramoyouTests" */;
\t\t\tbuildPhases = (
\t\t\t\t{TEST_SOURCES_UUID} /* Sources */,
\t\t\t\t{TEST_FRAMEWORKS_UUID} /* Frameworks */,
\t\t\t\t{TEST_RESOURCES_UUID} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{TEST_DEPENDENCY_UUID} /* PBXTargetDependency */,
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{TEST_SYNC_GROUP_UUID} /* SoramoyouTests */,
\t\t\t);
\t\t\tname = SoramoyouTests;
\t\t\tpackageProductDependencies = (
\t\t\t\t{FIREBASE_AUTH_UUID} /* FirebaseAuth */,
\t\t\t\t{FIREBASE_FIRESTORE_UUID} /* FirebaseFirestore */,
\t\t\t\t{FIREBASE_CRASHLYTICS_UUID} /* FirebaseCrashlytics */,
\t\t\t\t{FIREBASE_ANALYTICS_UUID} /* FirebaseAnalytics */,
\t\t\t\t{KINGFISHER_UUID} /* Kingfisher */,
\t\t\t\t{GOOGLE_MOBILE_ADS_UUID} /* GoogleMobileAds */,
\t\t\t);
\t\t\tproductName = SoramoyouTests;
\t\t\tproductReference = {TEST_PRODUCT_UUID} /* SoramoyouTests.xctest */;
\t\t\tproductType = "com.apple.product-type.bundle.unit-test";
\t\t}};
\t\t{UI_TEST_TARGET_UUID} /* SoramoyouUITests */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {UI_TEST_CONFIG_LIST_UUID} /* Build configuration list for PBXNativeTarget "SoramoyouUITests" */;
\t\t\tbuildPhases = (
\t\t\t\t{UI_TEST_SOURCES_UUID} /* Sources */,
\t\t\t\t{UI_TEST_FRAMEWORKS_UUID} /* Frameworks */,
\t\t\t\t{UI_TEST_RESOURCES_UUID} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{UI_TEST_DEPENDENCY_UUID} /* PBXTargetDependency */,
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{UI_TEST_SYNC_GROUP_UUID} /* SoramoyouUITests */,
\t\t\t);
\t\t\tname = SoramoyouUITests;
\t\t\tpackageProductDependencies = (
\t\t\t);
\t\t\tproductName = SoramoyouUITests;
\t\t\tproductReference = {UI_TEST_PRODUCT_UUID} /* SoramoyouUITests.xctest */;
\t\t\tproductType = "com.apple.product-type.bundle.ui-testing";
\t\t}};"""
        content = content.replace(target_section.group(2), target_section.group(2) + new_targets)
    
    # 8. PBXProjectセクションを更新（ターゲットリストに追加）
    project_section = re.search(rf'({PROJECT_UUID} = \{{[^}}]*targets = \()(.*?)(\);.*?}};\n/\* End PBXProject section \*/\n)', content, re.DOTALL)
    if project_section:
        new_targets_list = f"""{project_section.group(2)}
\t\t\t{MAIN_TARGET_UUID} /* Soramoyou */,
\t\t\t{TEST_TARGET_UUID} /* SoramoyouTests */,
\t\t\t{UI_TEST_TARGET_UUID} /* SoramoyouUITests */,"""
        content = content.replace(project_section.group(0), project_section.group(1) + new_targets_list + "\n\t\t\t" + project_section.group(3))
    
    # 9. TargetAttributesにテストターゲットを追加
    target_attrs = re.search(rf'(TargetAttributes = \{{)(.*?)(\}};)', content, re.DOTALL)
    if target_attrs:
        new_attrs = f"""{target_attrs.group(2)}
\t\t\t{TEST_TARGET_UUID} = {{
\t\t\t\tCreatedOnToolsVersion = 26.0;
\t\t\t\tTestTargetID = {MAIN_TARGET_UUID};
\t\t\t}};
\t\t\t{UI_TEST_TARGET_UUID} = {{
\t\t\t\tCreatedOnToolsVersion = 26.0;
\t\t\t\tTestTargetID = {MAIN_TARGET_UUID};
\t\t\t}};"""
        content = content.replace(target_attrs.group(0), target_attrs.group(1) + new_attrs + "\n\t\t\t" + target_attrs.group(3))
    
    # 10. PBXTargetDependencyセクションを追加
    dependency_section = re.search(r'(/\* Begin PBXTargetDependency section \*/\n)(.*?)(/\* End PBXTargetDependency section \*/\n)', content, re.DOTALL)
    if not dependency_section:
        # セクションが存在しない場合は追加
        target_section_end = content.find('/* End PBXNativeTarget section */')
        if target_section_end != -1:
            new_dependency = f"""
/* Begin PBXTargetDependency section */
\t\t{TEST_DEPENDENCY_UUID} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {MAIN_TARGET_UUID} /* Soramoyou */;
\t\t\ttargetProxy = {TEST_DEPENDENCY_UUID} /* PBXContainerItemProxy */;
\t\t}};
\t\t{UI_TEST_DEPENDENCY_UUID} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {MAIN_TARGET_UUID} /* Soramoyou */;
\t\t\ttargetProxy = {UI_TEST_DEPENDENCY_UUID} /* PBXContainerItemProxy */;
\t\t}};
/* End PBXTargetDependency section */

"""
            content = content[:target_section_end] + new_dependency + content[target_section_end:]
    
    # 11. XCBuildConfigurationセクションにテスト設定を追加
    build_config_section = re.search(r'(/\* Begin XCBuildConfiguration section \*/\n)(.*?)(/\* End XCBuildConfiguration section \*/\n)', content, re.DOTALL)
    if build_config_section:
        new_configs = f"""
\t\t{TEST_DEBUG_CONFIG_UUID} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = B7F79FDM78;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 26.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t\t"@loader_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.yoshidometoru.SoramoyouTests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/Soramoyou.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Soramoyou";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{TEST_RELEASE_CONFIG_UUID} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = B7F79FDM78;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 26.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t\t"@loader_path/Frameworks",
\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.yoshidometoru.SoramoyouTests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/Soramoyou.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Soramoyou";
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{UI_TEST_DEBUG_CONFIG_UUID} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = B7F79FDM78;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 26.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t\t"@loader_path/Frameworks",
\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.yoshidometoru.SoramoyouUITests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTEST_TARGET_NAME = Soramoyou;
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{UI_TEST_RELEASE_CONFIG_UUID} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = B7F79FDM78;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 26.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t\t"@loader_path/Frameworks",
\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.yoshidometoru.SoramoyouUITests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTEST_TARGET_NAME = Soramoyou;
\t\t\t}};
\t\t\tname = Release;
\t\t}};"""
        content = content.replace(build_config_section.group(2), build_config_section.group(2) + new_configs)
    
    # 12. XCConfigurationListセクションにテスト設定リストを追加
    config_list_section = re.search(r'(/\* Begin XCConfigurationList section \*/\n)(.*?)(/\* End XCConfigurationList section \*/\n)', content, re.DOTALL)
    if config_list_section:
        new_config_lists = f"""
\t\t{TEST_CONFIG_LIST_UUID} /* Build configuration list for PBXNativeTarget "SoramoyouTests" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{TEST_DEBUG_CONFIG_UUID} /* Debug */,
\t\t\t\t{TEST_RELEASE_CONFIG_UUID} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{UI_TEST_CONFIG_LIST_UUID} /* Build configuration list for PBXNativeTarget "SoramoyouUITests" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{UI_TEST_DEBUG_CONFIG_UUID} /* Debug */,
\t\t\t\t{UI_TEST_RELEASE_CONFIG_UUID} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};"""
        content = content.replace(config_list_section.group(2), config_list_section.group(2) + new_config_lists)
    
    return content

def main():
    project_file = "Soramoyou/Soramoyou.xcodeproj/project.pbxproj"
    
    try:
        with open(project_file, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # テストターゲットが既に存在するか確認
        if "SoramoyouTests" in content and "SoramoyouUITests" in content:
            print("テストターゲットは既に存在します。")
            return 0
        
        # テストターゲットを追加
        new_content = add_test_targets(content)
        
        # バックアップを作成
        with open(project_file + ".backup", 'w', encoding='utf-8') as f:
            f.write(content)
        
        # 新しい内容を書き込む
        with open(project_file, 'w', encoding='utf-8') as f:
            f.write(new_content)
        
        print("✅ テストターゲットの追加が完了しました。")
        print(f"📝 バックアップ: {project_file}.backup")
        return 0
        
    except Exception as e:
        print(f"❌ エラーが発生しました: {e}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())



