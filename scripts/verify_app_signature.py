#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify this app's SHA-256 CodeDirectory, identity and resource bindings."""
import hashlib
import plistlib
import struct


def verify_signature(executable, info_bytes, resources_bytes, resource_files=None):
    if executable[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a thin 64-bit Mach-O')
    command_count=struct.unpack_from('<I',executable,16)[0]
    cursor=32;signature=None
    for _ in range(command_count):
        command,size=struct.unpack_from('<II',executable,cursor)
        if size<8 or cursor+size>len(executable):raise ValueError('Invalid Mach-O load command')
        if command==0x1d:
            offset,length=struct.unpack_from('<II',executable,cursor+8)
            signature=executable[offset:offset+length]
        cursor+=size
    if signature is None or len(signature)<12:raise ValueError('Missing embedded signature')
    magic,length,count=struct.unpack_from('>III',signature)
    if magic!=0xfade0cc0 or length>len(signature):raise ValueError('Invalid signature superblob')
    directory=None
    for index in range(count):
        slot,offset=struct.unpack_from('>II',signature,12+index*8)
        if slot==0:
            cdmagic,cdlength=struct.unpack_from('>II',signature,offset)
            if cdmagic!=0xfade0c02:raise ValueError('Invalid CodeDirectory')
            directory=signature[offset:offset+cdlength]
    if directory is None:raise ValueError('Missing CodeDirectory')
    _,length,version,flags,hash_offset,identifier_offset,special_count,code_count,code_limit=struct.unpack_from('>9I',directory)
    hash_size,hash_type,platform,page_shift=struct.unpack_from('4B',directory,36)
    if hash_size!=32 or hash_type!=2 or not 0<page_shift<24:raise ValueError('Unsupported CodeDirectory hash/page format')
    identifier=directory[identifier_offset:].split(b'\0',1)[0].decode()
    expected=plistlib.loads(info_bytes)['CFBundleIdentifier']
    if identifier!=expected:raise ValueError('CodeDirectory identifier differs from bundle identifier')
    if special_count<3:raise ValueError('Missing Info.plist/resource signature slots')
    for slot,data in [(1,info_bytes),(3,resources_bytes)]:
        digest=directory[hash_offset-slot*hash_size:hash_offset-(slot-1)*hash_size]
        if len(digest)!=hash_size or digest!=hashlib.sha256(data).digest():raise ValueError('Info.plist or CodeResources hash mismatch')
    if code_limit>len(executable):raise ValueError('Invalid signed code limit')
    page_size=1<<page_shift
    if code_count!=(code_limit+page_size-1)//page_size:raise ValueError('Invalid code slot count')
    for index in range(code_count):
        data=executable[index*page_size:min((index+1)*page_size,code_limit)]
        digest=directory[hash_offset+index*hash_size:hash_offset+(index+1)*hash_size]
        if digest!=hashlib.sha256(data).digest():raise ValueError('Signed code page hash mismatch')
    resources_checked=0
    if resource_files is not None:
        resources=plistlib.loads(resources_bytes)
        for name, rule in resources.get('files2',{}).items():
            if not isinstance(rule,dict) or 'hash2' not in rule:raise ValueError('Unsupported resource rule')
            if name not in resource_files or hashlib.sha256(resource_files[name]).digest()!=rule['hash2']:
                raise ValueError('Sealed resource hash mismatch: '+name)
            resources_checked+=1
        if not resources_checked:raise ValueError('No sealed app resources')
    return {'identifier':identifier,'code_pages_verified':code_count,'info_plist_hash_verified':True,'code_resources_hash_verified':True,'sealed_resources_verified':resources_checked,'hash_type':'sha256'}
