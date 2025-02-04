/*
* Copyright (c) 2018-2019, NVIDIA CORPORATION.  All rights reserved.
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

#include <exception>
#include <sstream>
#include <cuda_runtime.h>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include <thrust/for_each.h>
#include <thrust/sort.h>
#include <rmm/rmm.h>
#include <rmm/thrust_rmm_allocator.h>
#include "NVStrings.h"
#include "NVStringsImpl.h"
#include "../custring_view.cuh"
#include "../util.h"

//
NVStrings* NVStrings::slice_replace( const char* repl, int start, int stop )
{
    if( !repl )
        throw std::invalid_argument("nvstrings::slice_replace parameter cannot be null");
    auto execpol = rmm::exec_policy(0);
    unsigned int replen = (unsigned int)strlen(repl);
    char* d_repl = device_alloc<char>(replen,0);
    CUDA_TRY( cudaMemcpyAsync(d_repl,repl,replen,cudaMemcpyHostToDevice))
    // compute size of output buffer
    unsigned int count = size();
    custring_view_array d_strings = pImpl->getStringsPtr();
    rmm::device_vector<size_t> lengths(count,0);
    size_t* d_lengths = lengths.data().get();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [d_strings, d_repl, replen, start, stop, d_lengths] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            if( !dstr )
                return;
            unsigned int len = 0;
            if( start < dstr->chars_count() )
                len = dstr->replace_size((unsigned)start,(unsigned)(stop-start),d_repl,replen);
            else
            {   // another odd pandas case: if out-of-bounds, just append
                int bytes = dstr->size() + replen;
                int nchars = dstr->chars_count() + custring_view::chars_in_string(d_repl,replen);
                len = custring_view::alloc_size(bytes,nchars);
            }
            len = ALIGN_SIZE(len);
            d_lengths[idx] = (size_t)len;
        });

    // create output object
    NVStrings* rtn = new NVStrings(count);
    char* d_buffer = rtn->pImpl->createMemoryFor(d_lengths);
    if( d_buffer==0 )
    {
        if( d_repl )
            RMM_FREE(d_repl,0);
        return rtn;
    }
    // create offsets
    rmm::device_vector<size_t> offsets(count,0);
    thrust::exclusive_scan(execpol->on(0),lengths.begin(),lengths.end(),offsets.begin());
    // do the slice and replace
    custring_view_array d_results = rtn->pImpl->getStringsPtr();
    size_t* d_offsets = offsets.data().get();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<size_t>(0), count,
        [d_strings, d_repl, replen, start, stop, d_buffer, d_offsets, d_results] __device__(size_t idx){
            custring_view* dstr = d_strings[idx];
            if( !dstr )
                return;
            char* buffer = d_buffer + d_offsets[idx];
            custring_view* dout = nullptr;
            if( start < dstr->chars_count() )
                dout = dstr->replace((unsigned)start,(unsigned)(stop-start),d_repl,replen,buffer);
            else
            {   // append for pandas consistency
                int bytes = dstr->size();
                char* ptr = buffer;
                memcpy( ptr, dstr->data(), bytes );
                ptr += bytes;
                memcpy( ptr, d_repl, replen );
                bytes += replen;
                dout = custring_view::create_from(buffer,buffer,bytes);
            }
            d_results[idx] = dout;
        });
    //
    if( d_repl )
        RMM_FREE(d_repl,0);
    return rtn;
}

// this should replace multiple occurrences up to maxrepl
NVStrings* NVStrings::replace( const char* str, const char* repl, int maxrepl )
{
    if( !str || !*str )
        throw std::invalid_argument("nvstrings::replace parameter cannot be null or empty");
    auto execpol = rmm::exec_policy(0);
    unsigned int ssz = (unsigned int)strlen(str);
    char* d_str = device_alloc<char>(ssz,0);
    CUDA_TRY( cudaMemcpyAsync(d_str,str,ssz,cudaMemcpyHostToDevice))
    unsigned int sszch = custring_view::chars_in_string(str,ssz);

    if( !repl )
        repl = "";
    unsigned int rsz = (unsigned int)strlen(repl);
    char* d_repl = device_alloc<char>(rsz,0);
    CUDA_TRY( cudaMemcpyAsync(d_repl,repl,rsz,cudaMemcpyHostToDevice))
    unsigned int rszch = custring_view::chars_in_string(repl,rsz);

    // compute size of the output
    unsigned int count = size();
    custring_view** d_strings = pImpl->getStringsPtr();
    rmm::device_vector<size_t> sizes(count,0);
    size_t* d_sizes = sizes.data().get();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [d_strings, d_str, ssz, sszch, d_repl, rsz, rszch, maxrepl, d_sizes] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            if( !dstr )
                return;
            int mxn = maxrepl;
            if( mxn < 0 )
                mxn = dstr->chars_count(); //max possible replaces for this string
            unsigned int bytes = dstr->size(), nchars = dstr->chars_count();
            int pos = dstr->find(d_str,ssz);
            // counting bytes and chars
            while((pos >= 0) && (mxn > 0))
            {
                bytes += rsz - ssz;
                nchars += rszch - sszch;
                pos = dstr->find(d_str,ssz,(unsigned)pos+sszch); // next one
                --mxn;
            }
            unsigned int size = custring_view::alloc_size(bytes,nchars);
            d_sizes[idx] = ALIGN_SIZE(size);
        });
    //
    // create output object
    NVStrings* rtn = new NVStrings(count);
    char* d_buffer = rtn->pImpl->createMemoryFor(d_sizes);
    if( d_buffer==0 )
    {
        RMM_FREE(d_str,0);
        RMM_FREE(d_repl,0);
        return rtn; // all strings are null
    }
    // create offsets
    rmm::device_vector<size_t> offsets(count,0);
    thrust::exclusive_scan(execpol->on(0),sizes.begin(),sizes.end(),offsets.begin());
    // do the thing
    custring_view_array d_results = rtn->pImpl->getStringsPtr();
    size_t* d_offsets = offsets.data().get();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [d_strings, d_str, ssz, sszch, d_repl, rsz, d_buffer, d_offsets, maxrepl, d_results] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            if( !dstr )
                return;
            int mxn = maxrepl;
            if( mxn < 0 )
                mxn = dstr->chars_count(); //max possible replaces for this string
            //
            char* buffer = d_buffer + d_offsets[idx];
            char* sptr = dstr->data();
            char* optr = buffer;
            unsigned int size = dstr->size();
            int pos = dstr->find(d_str,ssz), lpos=0;
            while((pos >= 0) && (mxn > 0))
            {                                                 // i:bbbbsssseeee
                int spos = dstr->byte_offset_for(pos);        //       ^
                memcpy(optr,sptr+lpos,spos-lpos);             // o:bbbb
                optr += spos - lpos;                          //       ^
                memcpy(optr,d_repl,rsz);                      // o:bbbbrrrr
                optr += rsz;                                  //           ^
                lpos = spos + ssz;                            // i:bbbbsssseeee
                pos = dstr->find(d_str,ssz,pos+sszch);        //           ^
                --mxn;
            }
            memcpy(optr,sptr+lpos,size-lpos);                 // o:bbbbrrrreeee
            unsigned int nsz = (unsigned int)(optr - buffer) + size - lpos;
            d_results[idx] = custring_view::create_from(buffer,buffer,nsz);
        });
    //
    RMM_FREE(d_str,0);
    RMM_FREE(d_repl,0);
    return rtn;
}

//
NVStrings* NVStrings::translate( std::pair<unsigned,unsigned>* utable, unsigned int tableSize )
{
    unsigned int count = size();
    custring_view_array d_strings = pImpl->getStringsPtr();
    auto execpol = rmm::exec_policy(0);

    // convert unicode table into utf8 table
    thrust::host_vector< thrust::pair<Char,Char> > htable(tableSize);
    for( unsigned int idx=0; idx < tableSize; ++idx )
    {
        htable[idx].first = u2u8(utable[idx].first);
        htable[idx].second = u2u8(utable[idx].second);
    }
    // could sort on the device; this table should not be very big
    thrust::sort(thrust::host, htable.begin(), htable.end(),
        [] __host__ (thrust::pair<Char,Char> p1, thrust::pair<Char,Char> p2) { return p1.first > p2.first; });

    // copy translate table to device memory
    rmm::device_vector< thrust::pair<Char,Char> > table(htable);
    thrust::pair<Char,Char>* d_table = table.data().get();

    // compute size of each new string
    rmm::device_vector<size_t> sizes(count,0);
    size_t* d_sizes = sizes.data().get();
    int tsize = tableSize;
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [d_strings, d_table, tsize, d_sizes] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            if( !dstr )
                return;
            const char* sptr = dstr->data();
            unsigned int bytes = dstr->size();
            unsigned int nchars = dstr->chars_count();
            for( unsigned int i=0; i < nchars; ++i )
            {
                Char ch = dstr->at(i);
                Char nch = ch;
                for( int t=0; t < tsize; ++t ) // replace with faster lookup
                    nch = ( ch==d_table[t].first ? d_table[t].second : nch );
                int bic = custring_view::bytes_in_char(ch);
                int nbic = (nch ? custring_view::bytes_in_char(nch) : 0);
                bytes += nbic - bic;
                if( nch==0 )
                    --nchars;
            }
            unsigned int size = custring_view::alloc_size(bytes,nchars);
            d_sizes[idx] = ALIGN_SIZE(size);
        });

    // create output object
    NVStrings* rtn = new NVStrings(count);
    char* d_buffer = rtn->pImpl->createMemoryFor(d_sizes);
    if( d_buffer==0 )
        return rtn;
    // create offsets
    rmm::device_vector<size_t> offsets(count,0);
    thrust::exclusive_scan(execpol->on(0),sizes.begin(),sizes.end(),offsets.begin());
    // do the translate
    custring_view_array d_results = rtn->pImpl->getStringsPtr();
    size_t* d_offsets = offsets.data().get();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [d_strings, d_buffer, d_offsets, d_table, tsize, d_results] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            if( !dstr )
                return;
            char* buffer = d_buffer + d_offsets[idx];
            const char* sptr = dstr->data();
            unsigned int nchars = dstr->chars_count();
            char* optr = buffer;
            int nsz = 0;
            for( unsigned int i=0; i < nchars; ++i )
            {
                Char ch = 0;
                unsigned int cw = custring_view::char_to_Char(sptr,ch);
                Char nch = ch;
                for( int t=0; t < tsize; ++t ) // replace with faster lookup
                    nch = ( ch==d_table[t].first ? d_table[t].second : nch );
                sptr += cw;
                if( nch==0 )
                    continue;
                unsigned int nbic = custring_view::Char_to_char(nch,optr);
                optr += nbic;
                nsz += nbic;
            }
            d_results[idx] = custring_view::create_from(buffer,buffer,nsz);
        });
    //
    return rtn;
}

//
// This will create a new instance replacing any nulls with the provided string.
// The parameter can be an empty string or any other string but not null.
NVStrings* NVStrings::fillna( const char* str )
{
    if( str==0 )
        throw std::invalid_argument("nvstrings::fillna parameter cannot be null");
    auto execpol = rmm::exec_policy(0);
    unsigned int ssz = (unsigned int)strlen(str);
    unsigned int asz = custring_view::alloc_size(str,ssz);
    char* d_str = device_alloc<char>(ssz+1,0);
    CUDA_TRY( cudaMemcpyAsync(d_str,str,ssz+1,cudaMemcpyHostToDevice))

    // compute size of the output
    unsigned int count = size();
    custring_view** d_strings = pImpl->getStringsPtr();
    rmm::device_vector<size_t> sizes(count,0);
    size_t* d_sizes = sizes.data().get();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [d_strings, d_str, asz, d_sizes] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            unsigned int size = asz;
            if( dstr )
                size = dstr->alloc_size();
            d_sizes[idx] = ALIGN_SIZE(size);
        });
    //
    NVStrings* rtn = new NVStrings(count); // create output object
    char* d_buffer = rtn->pImpl->createMemoryFor(d_sizes);
    rmm::device_vector<size_t> offsets(count,0); // create offsets
    thrust::exclusive_scan(execpol->on(0),sizes.begin(),sizes.end(),offsets.begin());
    // do the thing
    custring_view_array d_results = rtn->pImpl->getStringsPtr();
    size_t* d_offsets = offsets.data().get();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [d_strings, d_str, ssz, d_buffer, d_offsets, d_results] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            char* buffer = d_buffer + d_offsets[idx];
            if( dstr )
                dstr = custring_view::create_from(buffer,*dstr);
            else
                dstr = custring_view::create_from(buffer,d_str,ssz);
            d_results[idx] = dstr;
        });
    //
    RMM_FREE(d_str,0);
    return rtn;
}


// This will create a new instance replacing any nulls with the provided strings.
// The strings are matched by index. Non-null strings are not replaced.
NVStrings* NVStrings::fillna( NVStrings& strs )
{
    if( strs.size()!=size() )
        throw std::invalid_argument("nvstrings::fillna parameter must have the same number of strings");
    auto execpol = rmm::exec_policy(0);

    // compute size of the output
    auto count = size();
    custring_view** d_strings = pImpl->getStringsPtr();
    custring_view** d_repls = strs.pImpl->getStringsPtr();
    rmm::device_vector<size_t> sizes(count,0);
    size_t* d_sizes = sizes.data().get();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [d_strings, d_repls, d_sizes] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            custring_view* drepl = d_repls[idx];
            unsigned int size = 0;
            if( dstr )
                size = dstr->alloc_size();
            else if( drepl )
                size = drepl->alloc_size();
            else
                return; // both are null
            d_sizes[idx] = ALIGN_SIZE(size);
        });
    //
    NVStrings* rtn = new NVStrings(count); // create output object
    char* d_buffer = rtn->pImpl->createMemoryFor(d_sizes);
    rmm::device_vector<size_t> offsets(count,0); // create offsets
    thrust::exclusive_scan(execpol->on(0),sizes.begin(),sizes.end(),offsets.begin());
    // do the thing
    custring_view_array d_results = rtn->pImpl->getStringsPtr();
    size_t* d_offsets = offsets.data().get();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [d_strings, d_repls, d_buffer, d_offsets, d_results] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            custring_view* drepl = d_repls[idx];
            char* buffer = d_buffer + d_offsets[idx];
            if( dstr )
                d_results[idx] = custring_view::create_from(buffer,*dstr);
            else if( drepl )
                d_results[idx] = custring_view::create_from(buffer,*drepl);
        });
    //
    return rtn;
}

//
// The slice_replace method can do this too.
// This is easier to use and more efficient.
NVStrings* NVStrings::insert( const char* repl, int start )
{
    if( !repl )
        throw std::invalid_argument("nvstrings::slice_replace parameter cannot be null");
    auto execpol = rmm::exec_policy(0);
    unsigned int replen = (unsigned int)strlen(repl);
    char* d_repl = device_alloc<char>(replen,0);
    CUDA_TRY( cudaMemcpyAsync(d_repl,repl,replen,cudaMemcpyHostToDevice))
    // compute size of output buffer
    unsigned int count = size();
    custring_view_array d_strings = pImpl->getStringsPtr();
    rmm::device_vector<size_t> lengths(count,0);
    size_t* d_lengths = lengths.data().get();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
        [d_strings, d_repl, replen, start, d_lengths] __device__(unsigned int idx){
            custring_view* dstr = d_strings[idx];
            if( !dstr )
                return;
            unsigned int len = dstr->size();
            if( start <= (int)dstr->chars_count() )
                len = dstr->insert_size(d_repl,replen);
            len = ALIGN_SIZE(len);
            d_lengths[idx] = (size_t)len;
        });

    // create output object
    NVStrings* rtn = new NVStrings(count);
    char* d_buffer = rtn->pImpl->createMemoryFor(d_lengths);
    if( d_buffer==0 )
    {
        if( d_repl )
            RMM_FREE(d_repl,0);
        return rtn;
    }
    // create offsets
    rmm::device_vector<size_t> offsets(count,0);
    thrust::exclusive_scan(execpol->on(0),lengths.begin(),lengths.end(),offsets.begin());
    // do the insert
    custring_view_array d_results = rtn->pImpl->getStringsPtr();
    size_t* d_offsets = offsets.data().get();
    thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<size_t>(0), count,
        [d_strings, d_repl, replen, start, d_buffer, d_offsets, d_results] __device__(size_t idx){
            custring_view* dstr = d_strings[idx];
            if( !dstr )
                return;
            char* buffer = d_buffer + d_offsets[idx];
            custring_view* dout = custring_view::create_from(buffer,*dstr);
            if( start <= (int)dstr->chars_count() )
            {
                unsigned int pos = ( start < 0 ? dstr->chars_count() : (unsigned)start );
                dout->insert(pos,d_repl,replen);
            }
            d_results[idx] = dout;
        });
    //
    if( d_repl )
        RMM_FREE(d_repl,0);
    return rtn;
}
