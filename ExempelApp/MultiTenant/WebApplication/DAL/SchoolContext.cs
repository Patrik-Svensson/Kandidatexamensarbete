﻿using WebApplication.Models;
using System.Data.Entity;
using System.Data.Entity.ModelConfiguration.Conventions;
using System.Web;
using System.Diagnostics;
using System;

namespace WebApplication.DAL
{
    public class SchoolContext : DbContext
    {
        public SchoolContext()
            : this(GetConnectionString())
        { }

        public SchoolContext(string connectionString)
            : base(connectionString)
        {

        }
        public SchoolContext(ITenantIdProvider tenantIdProvider)
            : this(GetConnectionString(tenantIdProvider))
        { }

        private static string GetConnectionString()
        {
            return Common.ConnectionTenantDb.GetConnectionString();
        }

        private static string GetConnectionString(ITenantIdProvider tenantIdProvider)
        {
            return Common.ConnectionTenantDb.GetConnectionStringForTenant(tenantIdProvider.TenantId());
        }

        public DbSet<Course> Courses { get; set; }
        public DbSet<Department> Departments { get; set; }
        public DbSet<Enrollment> Enrollments { get; set; }
        public DbSet<Instructor> Instructors { get; set; }
        public DbSet<Student> Students { get; set; }
        public DbSet<OfficeAssignment> OfficeAssignments { get; set; }
        public DbSet<Person> People { get; set; }

        protected override void OnModelCreating(DbModelBuilder modelBuilder)
        {
            modelBuilder.Conventions.Remove<PluralizingTableNameConvention>();

            modelBuilder.Entity<Course>()
                .HasMany(c => c.Instructors).WithMany(i => i.Courses)
                .Map(t => t.MapLeftKey("CourseID")
                    .MapRightKey("InstructorID")
                    .ToTable("CourseInstructor"));

            modelBuilder.Entity<Department>().MapToStoredProcedures();
        }
    }
}