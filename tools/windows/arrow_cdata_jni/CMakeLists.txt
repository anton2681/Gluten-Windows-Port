cmake_minimum_required(VERSION 3.16)
project(arrow_cdata_jni_only)
set(CMAKE_CXX_STANDARD 17)

find_package(Java REQUIRED)
find_package(JNI REQUIRED)
include(UseJava)

# Default to the conventional arrow source location used by build-arrow-java.sh.
# Override by passing -DARROW_JAVA_C_DIR=<your-path>/java/c on the cmake command line.
if(NOT DEFINED ARROW_JAVA_C_DIR)
  set(ARROW_JAVA_C_DIR "$ENV{GLUTEN_REPO}/ep/_ep/arrow_ep/java/c")
endif()
if(NOT DEFINED ARROW_JAVA_C_DIR OR ARROW_JAVA_C_DIR STREQUAL "/ep/_ep/arrow_ep/java/c")
  set(ARROW_JAVA_C_DIR "C:/src/gluten/ep/_ep/arrow_ep/java/c")
endif()
message(STATUS "ARROW_JAVA_C_DIR = ${ARROW_JAVA_C_DIR}")

include_directories(${CMAKE_CURRENT_BINARY_DIR} ${ARROW_JAVA_C_DIR} ${JNI_INCLUDE_DIRS})

# Generate JNI headers from the Java classes
add_jar(arrow_java_jni_cdata_jar
    ${ARROW_JAVA_C_DIR}/src/main/java/org/apache/arrow/c/jni/CDataJniException.java
    ${ARROW_JAVA_C_DIR}/src/main/java/org/apache/arrow/c/jni/JniLoader.java
    ${ARROW_JAVA_C_DIR}/src/main/java/org/apache/arrow/c/jni/JniWrapper.java
    ${ARROW_JAVA_C_DIR}/src/main/java/org/apache/arrow/c/jni/PrivateData.java
    GENERATE_NATIVE_HEADERS arrow_java_jni_cdata_headers)

add_library(arrow_cdata_jni SHARED ${ARROW_JAVA_C_DIR}/src/main/cpp/jni_wrapper.cc)
target_link_libraries(arrow_cdata_jni PRIVATE arrow_java_jni_cdata_headers)
